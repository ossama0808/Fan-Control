import Foundation
import Combine
import IOKit.ps
import SMCKitCore

/// The running state of the whole app: polls the SMC, publishes readings, and
/// drives the fans according to each fan's configured mode.
@MainActor
public final class FanEngine: ObservableObject {

    @Published public private(set) var fans: [FanState] = []
    @Published public private(set) var readings: [SensorReading] = []
    @Published public private(set) var aggregates: [String: Double] = [:]
    @Published public private(set) var lastError: String?
    @Published public private(set) var helperStatus: HelperClient.Status = .notInstalled
    /// Which leg of a multi-leg profile is currently setting each fan's speed,
    /// so the UI can answer "why is the fan at this speed".
    @Published public private(set) var dominantLeg: [Int: String] = [:]
    @Published public private(set) var backstopReason: String?
    /// Set when the hardware will not accept fan commands at all, with a reason
    /// fit to show a user. Distinct from `lastError`, which means something went
    /// wrong; this is a normal state the machine puts itself in.
    @Published public private(set) var controlUnavailable: String?
    @Published public private(set) var onACPower: Bool = true

    @Published public var modes: [Int: FanMode] = [:] {
        didSet { settings.saveModes(modes); applyModes() }
    }

    @Published public var customPresets: [Preset] = [] {
        didSet { settings.saveCustomPresets(customPresets) }
    }

    public let settings: AppSettings
    public let history = SensorHistory()

    private let smc: SMC
    private let helper = HelperClient()
    private var sensors: [Sensor] = []
    private var timer: Timer?
    private var assertTimer: Timer?
    private var smoothed: [String: Double] = [:]
    private var lastLiveAt: [String: Date] = [:]
    private var lastCommanded: [Int: Double] = [:]
    private var legHeldSince: [Int: (leg: String, since: Date)] = [:]
    private var backstopSince: Date?
    /// Highest demand the firmware itself was seen making, per fan.
    private var firmwareFloor: [Int: (rpm: Double, at: Date)] = [:]

    /// Non-temperature readings the profiles and panel use.
    /// PSTR is system power in watts, PDTR adapter power, BRSC battery percent.
    private var extras: [String: Double] = [:]

    /// How often manual fan targets are re-sent to the SMC.
    ///
    /// This is not a preference and must not be raised. On Apple Silicon the SMC
    /// puts manual fan mode on a short *time-based* lease and hands the fan back
    /// to the firmware when it lapses, so a target set once simply stops applying.
    ///
    /// Measured on M4 Pro: with a write at t=0, the fan is still MANUAL at t=1s,
    /// already released at t=2s, and the firmware has retaken the target by t=3s.
    /// The lease is *not* tied to the SMC connection: holding the writing
    /// connection open across the timeout changes nothing, which is why a
    /// one-shot helper process is sufficient and no resident daemon is needed.
    ///
    /// Half a second gives roughly a 4x margin over the observed expiry, so a
    /// single missed tick (scheduler hiccup, app briefly busy) cannot drop a fan.
    private let assertInterval: TimeInterval = 0.5

    /// Exponential smoothing on falling temperatures. A rising reading passes
    /// through instantly — lagging a spike is the one error that risks hardware.
    private let smoothingAlpha: Double = 0.35

    /// Ramp limits, in RPM per second.
    ///
    /// The CPU aggregate moves at up to ~27 °C/s between samples and the Smart
    /// CPU leg is ~275 rpm/°C, so an unlimited curve would command the fan's
    /// entire range inside one second. Rising is limited to a swell rather than
    /// a step; falling is slower still because descending is what produces
    /// audible pumping, and there is no thermal cost to descending slowly.
    ///
    /// Both are engineering choices rather than measurements — tune by ear.
    public var rampUpRPMPerSecond: Double = 250
    public var rampDownRPMPerSecond: Double = 80

    /// Adopt a new setpoint only when it moves at least this much. At a fixed
    /// target of 1350 the fan's own regulation noise is roughly +/-25 rpm, so a
    /// smaller deadband would just chase noise.
    ///
    /// This suppresses *changes* only. The held setpoint is still re-sent every
    /// tick — skipping an unchanged write is exactly how a fan silently reverts.
    private let setpointDeadband: Double = 60

    /// Hold a losing leg briefly after another overtakes it, so two legs a few
    /// rpm apart do not swap every tick and flicker the "why" readout.
    private let legDwell: TimeInterval = 3

    public init(settings: AppSettings = .shared) throws {
        self.settings = settings
        self.smc = try SMC()
        self.modes = settings.loadModes()
        self.customPresets = settings.loadCustomPresets()
        discoverSensors()
        refresh()
    }

    // MARK: - Discovery

    private func discoverSensors() {
        guard let keys = try? smc.allKeys() else { return }
        sensors = keys.compactMap { SensorCatalog.sensor(for: $0.description) }
                      .sorted {
                          $0.group.sortOrder == $1.group.sortOrder
                              ? $0.key < $1.key
                              : $0.group.sortOrder < $1.group.sortOrder
                      }
    }

    public var sensorCount: Int { sensors.count }
    public var liveSensorCount: Int { readings.filter(\.isLive).count }

    // MARK: - Polling

    public func start() {
        stop()
        // Sensor polling. Clamped while a multi-leg profile is active: aggregates
        // are only recomputed on this timer while curves evaluate at 0.5 s, so a
        // slow poll would drive a profile from stale data.
        let interval = hasProfileActive ? min(settings.pollInterval, 2.0)
                                        : settings.pollInterval
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        let a = Timer(timeInterval: assertInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.applyModes() }
        }
        RunLoop.main.add(a, forMode: .common)
        assertTimer = a
    }

    public func stop() {
        timer?.invalidate(); timer = nil
        assertTimer?.invalidate(); assertTimer = nil
    }

    private var hasProfileActive: Bool {
        modes.values.contains { if case .multi = $0 { true } else { false } }
    }

    public func refresh() {
        let hs = helper.status()
        if hs != helperStatus { helperStatus = hs }
        let ac = Self.isOnACPower()
        if ac != onACPower { onACPower = ac }

        var rejectedInput: [(sensor: Sensor, celsius: Double)] = []
        for s in sensors {
            guard let v = try? smc.readDouble(SMCKey(s.key)) else { continue }
            rejectedInput.append((s, v))
        }
        let fakes = SensorCatalog.rejectingFakes(rejectedInput)
        readings = rejectedInput.filter { !fakes.contains($0.sensor.key) }
                                .map { SensorReading(sensor: $0.sensor, celsius: $0.celsius) }

        readExtras()
        recomputeAggregates()
        refreshFans()
        recordHistory()
    }

    private func readExtras() {
        for k in ["PSTR", "PDTR", "BRSC"] {
            if let v = try? smc.readDouble(SMCKey(k)) { extras[k] = v }
        }
    }

    public func extra(_ key: String) -> Double? { extras[key] }

    private func recomputeAggregates() {
        var next: [String: Double] = [:]
        let now = Date()

        for agg in AggregateSensor.all {
            let vals: [Double]
            if !agg.keys.isEmpty {
                vals = readings.filter { agg.keys.contains($0.sensor.key) && $0.isLive }
                               .map(\.celsius)
            } else {
                vals = readings.filter { agg.groups.contains($0.sensor.group) && $0.isLive }
                               .map(\.celsius)
            }
            guard let hottest = vals.max() else { continue }
            lastLiveAt[agg.id] = now

            // Smooth downwards only; let a rise through immediately.
            let prev = smoothed[agg.id]
            let v = (prev == nil || hottest > prev!)
                ? hottest
                : prev! + smoothingAlpha * (hottest - prev!)
            smoothed[agg.id] = v
            next[agg.id] = v
        }

        // A group that goes dark must not keep decaying from a stale hot value
        // forever, or it will read as warm-but-cooling when it is simply absent.
        for (id, at) in lastLiveAt where now.timeIntervalSince(at) > 10 {
            smoothed.removeValue(forKey: id)
            lastLiveAt.removeValue(forKey: id)
        }

        if let watts = extras["PSTR"] { next["agg.systemPower"] = watts }
        aggregates = next
    }

    private func refreshFans() {
        let n = (try? smc.readDouble(SMCKey("FNum"))).map { Int($0) } ?? 0
        let now = Date()
        fans = (0..<n).compactMap { i in
            guard let ac = try? smc.readDouble(SMCKey("F\(i)Ac")) else { return nil }
            let target = (try? smc.readDouble(SMCKey("F\(i)Tg"))) ?? 0
            let manual = ((try? smc.readDouble(SMCKey("F\(i)Md"))) ?? 0) == 1

            // While the firmware holds a fan, its target IS the firmware's own
            // demand. Remembering the highest recent value costs nothing and
            // gives us a hard lower bound that guarantees no profile can ever
            // command less air than auto would have.
            if !manual {
                let prev = firmwareFloor[i]
                if prev == nil || target > prev!.rpm
                    || now.timeIntervalSince(prev!.at) > 600 {
                    firmwareFloor[i] = (target, now)
                }
            }

            return FanState(
                index: i, currentRPM: ac, targetRPM: target,
                minRPM: (try? smc.readDouble(SMCKey("F\(i)Mn"))) ?? 0,
                maxRPM: (try? smc.readDouble(SMCKey("F\(i)Mx"))) ?? 0,
                hardwareIsManual: manual
            )
        }
    }

    private func recordHistory() {
        var snapshot: [String: Double] = [:]
        for f in fans { snapshot["fan\(f.index)"] = f.currentRPM }
        for (k, v) in aggregates { snapshot[k] = v }
        history.record(snapshot)
    }

    // MARK: - Lookup

    public func temperature(forSensorID id: String) -> Double? {
        if let v = aggregates[id] { return v }
        return readings.first { $0.sensor.key == id }?.celsius
    }

    public func label(forSensorID id: String) -> String {
        if let a = AggregateSensor.named(id) { return a.label }
        if id == "agg.systemPower" { return "System power" }
        return readings.first { $0.sensor.key == id }?.sensor.label ?? id
    }

    /// Human-readable reason the given fan is running at its current speed.
    public func explanation(forFan index: Int) -> String? {
        guard let leg = dominantLeg[index] else { return nil }
        if let backstopReason { return "Thermal backstop: \(label(forSensorID: backstopReason))" }
        return label(forSensorID: legSensorID(leg) ?? leg)
    }

    private func legSensorID(_ legID: String) -> String? {
        for mode in modes.values {
            if case .multi(let legs) = mode,
               let l = legs.first(where: { $0.id == legID }) { return l.sensorID }
        }
        return nil
    }

    // MARK: - Applying modes

    private func applyModes() {
        guard helperStatus == .ready else { return }

        // When the Mac is cool enough, the firmware powers the fans down
        // completely — they report 0 rpm with a 0 target — and in that state the
        // SMC rejects every fan write, including a request to hand control back.
        // Verified on M4 Pro with nothing else running: writes return SMC result
        // 130 until the firmware starts the fans again on its own.
        //
        // There is nothing to fix and nothing to cool, so say so plainly rather
        // than retrying into an error the user cannot act on. Control resumes by
        // itself once the fans spin up.
        if !fans.isEmpty, fans.allSatisfy({ $0.currentRPM == 0 && $0.targetRPM == 0 }) {
            let reason = "Fans are off — the Mac is cool enough that the firmware stopped them"
            if controlUnavailable != reason { controlUnavailable = reason }
            if lastError != nil { lastError = nil }
            return
        }
        if controlUnavailable != nil { controlUnavailable = nil }

        let now = Date()
        var targets: [Int: Double] = [:]
        var releases: [Int] = []

        // The backstop sits above every profile and must hold continuously
        // before firing, so one bad sample cannot slam the fans to maximum.
        let breach = ThermalBackstop.breached { self.temperature(forSensorID: $0) }
        if let breach {
            if backstopSince == nil { backstopSince = now }
            if now.timeIntervalSince(backstopSince!) >= ThermalBackstop.dwell,
               backstopReason != breach {
                backstopReason = breach
            }
        } else {
            backstopSince = nil
            if backstopReason != nil { backstopReason = nil }
        }

        for fan in fans {
            let mode = effectiveMode(for: fan.index)

            if mode.isAuto && backstopReason == nil {
                // Release whenever the hardware still reports manual, not only
                // on a transition we made. This recovers a machine whose previous
                // run was SIGKILLed with fans pinned; the write is idempotent and
                // stops as soon as the SMC agrees.
                if fan.hardwareIsManual { releases.append(fan.index) }
                lastCommanded[fan.index] = nil
                if dominantLeg[fan.index] != nil { dominantLeg[fan.index] = nil }
                continue
            }

            var rpm: Double
            if backstopReason != nil {
                // Deliberately bypasses smoothing and the ramp limiter. This is
                // the one case where an audible surge is the correct behaviour.
                rpm = fan.maxRPM
                dominantLeg[fan.index] = "backstop"
            } else {
                guard let demand = mode.demand(fanMinimum: fan.minRPM, lookup: { id in
                    self.temperature(forSensorID: id)
                }) else { continue }

                if demand.blind {
                    lastError = "\(fan.name): sensors unreadable — running at maximum"
                    rpm = fan.maxRPM
                    dominantLeg[fan.index] = nil
                } else {
                    rpm = demand.rpm
                    rpm = applyLegDwell(fan: fan, demand: demand, rpm: rpm, now: now)
                }

                rpm = max(rpm, firmwareFloor[fan.index]?.rpm ?? 0)

                // ORDER MATTERS. The deadband must judge the *demand*, not the
                // ramp-limited step toward it. Applied the other way round, a
                // descent moves only rampDown * assertInterval = 40 rpm per
                // tick, which is smaller than the 60 rpm deadband, so every
                // downward step was swallowed and the setpoint could rise but
                // never fall — fans stayed pinned at their high-water mark long
                // after the load that caused it had gone.
                if let prev = lastCommanded[fan.index],
                   abs(rpm - prev) < setpointDeadband {
                    rpm = prev
                } else {
                    rpm = applyRampLimit(fan: fan, desired: rpm)
                }
            }

            targets[fan.index] = rpm.clamped(to: fan.minRPM...fan.maxRPM)
        }

        // Written every tick, unconditionally: the deadband governs whether the
        // setpoint *changes*, never whether it is re-sent. Dispatched off the
        // main actor so the ~100 ms process spawn cannot delay the next renewal.
        helper.setFansAsync(targets, releasing: releases) { message in
            Task { @MainActor [weak self] in self?.lastError = message }
        }
        for (i, r) in targets { lastCommanded[i] = r }
        if backstopReason == nil && lastError != nil { lastError = nil }
    }

    /// A profile is stored once under `fallback`; every fan follows it unless the
    /// user has given that specific fan its own mode.
    private func effectiveMode(for index: Int) -> FanMode {
        if let m = modes[index] { return m }
        return .auto
    }

    private func applyLegDwell(fan: FanState, demand: FanDemand,
                               rpm: Double, now: Date) -> Double {
        guard let leg = demand.dominantLegID else { return rpm }
        if let held = legHeldSince[fan.index], held.leg != leg,
           now.timeIntervalSince(held.since) < legDwell {
            return lastCommanded[fan.index] ?? rpm
        }
        if legHeldSince[fan.index]?.leg != leg {
            legHeldSince[fan.index] = (leg, now)
        }
        if dominantLeg[fan.index] != leg { dominantLeg[fan.index] = leg }
        return rpm
    }

    private func applyRampLimit(fan: FanState, desired: Double) -> Double {
        guard let prev = lastCommanded[fan.index] else { return desired }
        let up = rampUpRPMPerSecond * assertInterval
        let down = rampDownRPMPerSecond * assertInterval
        if desired > prev { return min(desired, prev + up) }
        if desired < prev { return max(desired, prev - down) }
        return desired
    }

    private static func isOnACPower() -> Bool {
        IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() != nil
    }

    // MARK: - Presets

    public var allPresets: [Preset] { Preset.builtIns + customPresets }

    @discardableResult
    public func saveCurrentAsPreset(named name: String) -> Preset {
        var p = Preset(name: name, modes: modes, fallback: .auto)
        for fan in fans where p.modes[fan.index] == nil {
            p.modes[fan.index] = modes[fan.index] ?? .auto
        }
        customPresets.append(p)
        settings.activePresetID = p.id
        return p
    }

    public func deletePreset(_ preset: Preset) {
        guard !preset.isBuiltIn else { return }
        customPresets.removeAll { $0.id == preset.id }
        if settings.activePresetID == preset.id { settings.activePresetID = nil }
    }

    public func renamePreset(_ preset: Preset, to name: String) {
        guard let i = customPresets.firstIndex(where: { $0.id == preset.id }) else { return }
        customPresets[i].name = name
    }

    public func setMode(_ mode: FanMode, for index: Int) { modes[index] = mode }

    public func applyPreset(_ preset: Preset) {
        var next = modes
        for fan in fans { next[fan.index] = adjust(preset.mode(for: fan), for: fan) }
        modes = next
        settings.activePresetID = preset.id
        legHeldSince.removeAll()
        start()   // re-clamp the poll interval if a profile just became active
    }

    /// Battery-aware adjustment applied when a profile is selected.
    ///
    /// Cool's raised floor exists to keep surfaces comfortable, which is not
    /// worth continuous fan power on battery — and the machine runs cooler on
    /// battery anyway, since charging is itself a large heat source. Smart's
    /// protective legs are never relaxed: component protection is not a
    /// power-saving negotiation.
    private func adjust(_ mode: FanMode, for fan: FanState) -> FanMode {
        guard case .multi(let legs) = mode else { return mode }
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            // The user has explicitly asked the system to prioritise something
            // other than performance or comfort. Respect that.
            return .auto
        }
        guard !onACPower else { return mode }
        let adjusted = legs.compactMap { leg -> FanCurveLeg? in
            if leg.id == "powerFF" { return nil }   // knee is calibrated to AC draw
            var l = leg
            if l.r0 == Preset.coolFloorRPM { l.r0 = 0 }   // 0 == this fan's minimum
            return l
        }
        return .multi(legs: adjusted)
    }

    /// Hand every fan back to the firmware.
    ///
    /// Called on quit and on signal-driven termination. This matters more than
    /// it looks: manual mode does not reliably expire on its own, so a fan left
    /// commanded by a dead process can stay pinned indefinitely.
    public func restoreAutoOnExit() {
        try? helper.setAllAuto()
    }
}
