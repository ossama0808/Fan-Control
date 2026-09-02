import Foundation

/// How a single fan is being driven.
public enum FanMode: Codable, Hashable {
    /// Hand the fan back to the system's own thermal management.
    case auto
    /// Hold a fixed RPM.
    case constant(rpm: Double)
    /// Map a sensor's temperature onto an RPM range.
    /// Below `minTemp` the fan sits at `minRPM`; above `maxTemp` it sits at
    /// `maxRPM`; in between it interpolates linearly.
    case sensorBased(sensorID: String, minTemp: Double, maxTemp: Double,
                     minRPM: Double, maxRPM: Double)
    /// Several independent ramps evaluated together; the fan runs at whichever
    /// leg is currently asking for the most air. This is what lets a profile
    /// react to the component that is actually in trouble instead of watching
    /// one fixed sensor.
    case multi(legs: [FanCurveLeg])

    public var isAuto: Bool { if case .auto = self { true } else { false } }

    public var shortDescription: String {
        switch self {
        case .auto: "Auto"
        case .constant(let r): String(format: "Constant %.0f RPM", r)
        case .sensorBased(_, let t0, let t1, _, _):
            String(format: "Sensor-based %.0f–%.0f°C", t0, t1)
        case .multi(let legs):
            "Profile (\(legs.count) inputs)"
        }
    }
}

/// One ramp within a multi-leg profile: as `sensorID` goes from `t0` to `t1`,
/// the demanded speed goes from `r0` to `r1`.
public struct FanCurveLeg: Codable, Hashable, Identifiable {
    public var id: String
    public var sensorID: String
    public var t0: Double
    public var t1: Double
    /// Floor speed. Zero is a sentinel meaning "this fan's own minimum", used so
    /// a leg table can be written once and applied to fans with different ranges.
    public var r0: Double
    public var r1: Double

    public init(id: String, sensorID: String, t0: Double, t1: Double,
                r0: Double, r1: Double) {
        self.id = id; self.sensorID = sensorID
        self.t0 = t0; self.t1 = t1; self.r0 = r0; self.r1 = r1
    }

    public func floor(fanMinimum: Double) -> Double { r0 == 0 ? fanMinimum : r0 }

    /// Demand for a given input value, or nil if the input is unusable.
    public func demand(_ value: Double?, fanMinimum: Double) -> Double? {
        guard let v = value else { return nil }
        let lo = floor(fanMinimum: fanMinimum)
        guard t1 > t0 else { return v >= t1 ? r1 : lo }
        let f = ((v - t0) / (t1 - t0)).clamped(to: 0...1)
        return lo + f * (r1 - lo)
    }
}

/// The outcome of evaluating a mode, including which input won.
public struct FanDemand {
    public let rpm: Double
    public let dominantLegID: String?
    /// True when every input a profile depends on was unreadable. The caller
    /// must treat this as a fault, not as "no demand".
    public let blind: Bool

    public init(rpm: Double, dominantLegID: String? = nil, blind: Bool = false) {
        self.rpm = rpm; self.dominantLegID = dominantLegID; self.blind = blind
    }
}

/// What the SMC reports a fan's control mode to be.
public enum FanHardwareMode: Int, Hashable {
    /// The firmware is driving the fan.
    case auto = 0
    /// We are driving the fan.
    case manual = 1
    /// The firmware has powered the fan down entirely, which it does whenever
    /// the machine is cool enough. `F<n>Md` is not writable in this state, but
    /// the fan is not unreachable: writing `Ftst` wakes it, after which normal
    /// control works. The helper does that automatically.
    case off = 3
    case unknown = -1
}

/// Live state of one physical fan.
public struct FanState: Identifiable, Hashable {
    public let index: Int
    public var currentRPM: Double
    public var targetRPM: Double
    public var minRPM: Double
    public var maxRPM: Double
    public var hardwareMode: FanHardwareMode
    public var id: Int { index }

    public init(index: Int, currentRPM: Double, targetRPM: Double,
                minRPM: Double, maxRPM: Double, hardwareMode: FanHardwareMode) {
        self.index = index; self.currentRPM = currentRPM; self.targetRPM = targetRPM
        self.minRPM = minRPM; self.maxRPM = maxRPM; self.hardwareMode = hardwareMode
    }

    public var hardwareIsManual: Bool { hardwareMode == .manual }
    /// True when the firmware has powered this fan down and nothing can drive it.
    public var isPoweredOff: Bool { hardwareMode == .off }

    public var name: String { "Fan \(index + 1)" }

    /// The fan's speed range, always well-formed.
    ///
    /// Never build a range directly from `minRPM...maxRPM`: those come from
    /// separate SMC reads, and a single failed read yields 0, so a fan whose
    /// minimum read fine and whose maximum did not gives `1350...0`. In Swift
    /// that is not a bad value, it is an immediate trap that takes the whole app
    /// down — and the moment a read is most likely to fail is exactly when the
    /// user switches profile and the SMC is busiest.
    public var rpmRange: ClosedRange<Double> {
        let lo = Swift.min(minRPM, maxRPM)
        let hi = Swift.max(minRPM, maxRPM)
        return hi > lo ? lo...hi : lo...(lo + 1)
    }

    /// 0…1 position of the current speed within the fan's physical range.
    public var loadFraction: Double {
        guard maxRPM > minRPM else { return 0 }
        return ((currentRPM - minRPM) / (maxRPM - minRPM)).clamped(to: 0...1)
    }
}

/// One temperature reading at a point in time.
public struct SensorReading: Identifiable, Hashable {
    public let sensor: Sensor
    public let celsius: Double
    public var id: String { sensor.key }
    /// Uses the band for this sensor's own group. A single global band cannot
    /// work — 40 °C is a normal enclosure reading and also exactly what a
    /// power-gated CPU core reports when it is saying nothing at all.
    public var isLive: Bool { SensorCatalog.isLive(celsius, group: sensor.group) }
}

public extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self {
        min(max(self, r.lowerBound), r.upperBound)
    }
}

public extension FanMode {
    /// Evaluate the mode against a temperature, returning the RPM to command.
    /// Returns nil for `.auto` (nothing to command — the SMC drives it).
    func targetRPM(temperature: Double?) -> Double? {
        switch self {
        case .auto:
            return nil
        case .constant(let rpm):
            return rpm
        case .sensorBased(_, let t0, let t1, let r0, let r1):
            // A dead/parked sensor must fail loud, not fail slow: if we cannot
            // read the temperature we command full speed rather than silently
            // leaving the fan at minimum while the machine heats up.
            guard let t = temperature, SensorCatalog.isLive(t) else { return r1 }
            guard t1 > t0 else { return t >= t1 ? r1 : r0 }
            let f = ((t - t0) / (t1 - t0)).clamped(to: 0...1)
            return r0 + f * (r1 - r0)
        case .multi:
            // Multi-leg modes need per-leg inputs; use `demand(fanMinimum:lookup:)`.
            return nil
        }
    }

    /// Evaluate against a lookup of sensor id -> current value.
    ///
    /// A single dead leg is *skipped* rather than forced to maximum: in a
    /// multi-input profile one dark sensor group would otherwise pin the fans at
    /// full speed permanently. Only losing every leg is a fault, and that case
    /// is reported through `FanDemand.blind` so the caller can fail loud.
    func demand(fanMinimum: Double, lookup: (String) -> Double?) -> FanDemand? {
        switch self {
        case .auto:
            return nil
        case .constant(let rpm):
            return FanDemand(rpm: rpm)
        case .sensorBased(let id, _, _, _, let r1):
            let v = lookup(id)
            guard let rpm = targetRPM(temperature: v) else { return nil }
            return FanDemand(rpm: rpm, dominantLegID: id, blind: v == nil ? true : false)
                .withFallback(r1)
        case .multi(let legs):
            var best: (rpm: Double, id: String)?
            for leg in legs {
                guard let d = leg.demand(lookup(leg.sensorID), fanMinimum: fanMinimum)
                else { continue }
                if best == nil || d > best!.rpm { best = (d, leg.id) }
            }
            guard let best else {
                // Every input is dark. Command maximum and say so.
                return FanDemand(rpm: .greatestFiniteMagnitude, blind: true)
            }
            return FanDemand(rpm: best.rpm, dominantLegID: best.id)
        }
    }
}

private extension FanDemand {
    func withFallback(_ maxRPM: Double) -> FanDemand {
        blind ? FanDemand(rpm: maxRPM, dominantLegID: dominantLegID, blind: true) : self
    }
}
