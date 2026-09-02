import Foundation
import SMCKitCore

/// A physical temperature sensor exposed by the SMC.
public struct Sensor: Identifiable, Hashable {
    public let key: String
    public let group: SensorGroup
    public let label: String
    public var id: String { key }

    public init(key: String, group: SensorGroup, label: String) {
        self.key = key; self.group = group; self.label = label
    }
}

public enum SensorGroup: String, CaseIterable, Hashable, Codable {
    case cpuPerformance = "CPU performance cores"
    case cpuEfficiency  = "CPU efficiency cores"
    case gpu            = "GPU"
    case soc            = "SoC"
    case memory         = "Memory"
    case powerDelivery  = "Power delivery"
    case storage        = "Storage"
    case battery        = "Battery"
    case enclosureUpper = "Top case"
    case enclosureLower = "Bottom case"
    case internalAir    = "Internal airflow"
    case roomAir        = "Room air"
    case wireless       = "Wireless"
    case display        = "Display"
    case other          = "Other"

    public var sortOrder: Int {
        switch self {
        case .cpuPerformance: 0; case .cpuEfficiency: 1; case .gpu: 2
        case .soc: 3; case .memory: 4; case .storage: 5; case .battery: 6
        case .enclosureUpper: 7; case .enclosureLower: 8; case .internalAir: 9
        case .roomAir: 10; case .powerDelivery: 11; case .wireless: 12
        case .display: 13; case .other: 14
        }
    }

    /// Physically plausible band for this kind of sensor.
    ///
    /// A single global band cannot work: 40 °C is a normal enclosure reading and
    /// simultaneously the exact value a power-gated P-core reports when it is
    /// telling you nothing at all.
    public var plausible: ClosedRange<Double> {
        switch self {
        case .cpuPerformance, .cpuEfficiency, .gpu, .soc, .memory:
            return 20...125
        case .powerDelivery:
            return 20...125
        case .storage:
            return 10...110
        case .battery:
            return 0...80
        case .enclosureUpper, .enclosureLower, .internalAir, .roomAir:
            return 5...90
        case .wireless, .display, .other:
            return 5...125
        }
    }
}

public enum SensorCatalog {

    /// Wide fallback band, used only where a group is not yet known.
    public static let plausible: ClosedRange<Double> = 1.0...125.0

    public static func isLive(_ celsius: Double) -> Bool { plausible.contains(celsius) }

    public static func isLive(_ celsius: Double, group: SensorGroup) -> Bool {
        group.plausible.contains(celsius)
    }

    /// Classify a raw SMC key into a group and a human label.
    ///
    /// Apple documents none of this. Assignments below are ordered most-specific
    /// first and are backed by measurement on Mac16,7 (M4 Pro) wherever a label
    /// is asserted with confidence; see `evidence` notes inline.
    public static func classify(_ key: String) -> (SensorGroup, String)? {
        guard key.hasPrefix("T"), key.count == 4 else { return nil }

        // --- Specific keys, established by experiment ---------------------
        switch key {
        // Top-case skin. Under a 120 s all-core burn that moved the die +23.7 °C
        // these moved +0.37/+0.42 °C, and under 88 s of sustained NAND writes
        // that moved TH0x +3.4 °C they moved +0.03/+0.19 °C. They respond to
        // neither die nor SSD, only to accumulated whole-machine energy, which
        // is what an outer surface does. (This contradicts published tables
        // that label them "SSD Controller"; that label is falsified here, and
        // was already thermally impossible with an on-die NVMe controller.)
        case "Ts0P": return (.enclosureUpper, "Palm rest 1")
        case "Ts1P": return (.enclosureUpper, "Palm rest 2")

        // Enclosure base. TB0T == max(TB1T, TB2T) held on every sample, so it is
        // the correct single aggregate key. t50 = 64 s, among the slowest on the
        // machine, and zero response to disk load: thermal-mass behaviour.
        // Doubles as the battery sensor — in this chassis they are the same mass.
        case "TB0T": return (.enclosureLower, "Enclosure base (max)")
        case "TB1T": return (.enclosureLower, "Enclosure base 1")
        case "TB2T": return (.enclosureLower, "Enclosure base 2")

        // Room air. Inert to machine load: 0.00 °C rise across a burn that took
        // the die to 99 °C; it tracked the room down instead.
        case "TAOL": return (.roomAir, "Outside lid")
        case "TVA0": return (.roomAir, "Virtual ambient")

        // Verified family maxima — one key replaces a whole scan.
        case "TCMz": return (.cpuPerformance, "CPU die (max)")
        case "TCMb": return (.cpuPerformance, "CPU die (average)")
        case "TUDX": return (.soc,            "Uncore die (max)")
        case "TVXh": return (.memory,         "Memory in-package (max)")
        case "TPDX": return (.powerDelivery,  "Power delivery (max)")
        case "TRDX": return (.powerDelivery,  "Rail delivery (max)")
        case "TH0x": return (.storage,        "NAND (max)")
        default: break
        }

        let p2 = String(key.prefix(2))
        let suffix = String(key.dropFirst(2))

        switch p2 {
        case "Tp": return (.cpuPerformance, "P-core \(suffix)")
        case "Te": return (.cpuEfficiency,  "E-core \(suffix)")
        case "Tg": return (.gpu,            "GPU \(suffix)")
        case "Ts": return (.soc,            "SoC \(suffix)")
        case "TC": return (.cpuPerformance, "CPU \(suffix)")
        case "TB": return (.battery,        "Battery \(suffix)")
        case "TH": return (.storage,        "SSD \(suffix)")
        case "TW": return (.wireless,       "Wi-Fi \(suffix)")

        case "Ta", "TA":
            // NOT room air. The hottest of these (TaTP, "top proximity") peaked
            // at 59 °C and rose 12 °C under load — it is internal air near the
            // heatsink. Treating this family as ambient is what made an earlier
            // version of this catalogue bind a "keep the case cool" profile to
            // a sensor that tracks the SoC.
            return (.internalAir, "Internal air \(suffix)")

        case "TD":
            // Two different families sharing a prefix. The TD00–TD24 grid sits
            // in the display lid and stayed flat (≤0.33 °C) through a burn that
            // moved the base 8–12 °C. The letter-suffixed ones are board diodes
            // in the base and did respond.
            let isLidGrid = suffix.allSatisfy(\.isNumber)
            return isLidGrid ? (.display, "Display \(suffix)")
                             : (.enclosureLower, "Board diode \(suffix)")

        case "TM": return (.memory, "Memory \(suffix)")
        case "TV", "TP", "TU", "TR", "Tf", "TS", "TF", "TG":
            return (.powerDelivery, "Regulator \(key)")
        default:
            return (.other, key)
        }
    }

    public static func sensor(for key: String) -> Sensor? {
        guard let (g, l) = classify(key) else { return nil }
        return Sensor(key: key, group: g, label: l)
    }

    /// Reject readings that are structurally fake rather than merely odd.
    ///
    /// Some SMC keys are setpoints or unpopulated slots that report a fixed
    /// value forever. Six `Ta*` keys on this machine all read exactly 9.10, and
    /// a power-gated core cluster can report exactly 40.00 across fifty keys at
    /// once — both sit inside any sane temperature band and are indistinguishable
    /// from a real reading in isolation.
    ///
    /// The tell is that they agree *bit-exactly* with their siblings, which real
    /// independent sensors essentially never do. This needs no key blocklist,
    /// so it keeps working on hardware nobody has characterised.
    public static func rejectingFakes(_ readings: [(sensor: Sensor, celsius: Double)])
        -> Set<String>
    {
        var rejected: Set<String> = []
        let byGroup = Dictionary(grouping: readings, by: \.sensor.group)
        for (_, rows) in byGroup {
            let byValue = Dictionary(grouping: rows) { $0.celsius }
            for (value, sharing) in byValue where sharing.count >= 3 {
                // Real sensors do drift into agreement transiently, but not on a
                // round number. Requiring both cuts false positives sharply.
                let isRound = (value * 10).rounded() == value * 10
                if isRound { sharing.forEach { rejected.insert($0.sensor.key) } }
            }
        }
        return rejected
    }
}

/// What an aggregate measures, so the UI can format it and the control loop can
/// avoid treating watts as degrees.
public enum SensorUnit: String, Codable, Hashable {
    case celsius, watts, percent
}

/// A named value computed across several physical sensors.
///
/// Binding control to one raw core key is unreliable — clusters power-gate and
/// their sensors go dark — so curves bind to these instead.
public struct AggregateSensor: Identifiable, Hashable {
    public let id: String
    public let label: String
    public let groups: Set<SensorGroup>
    /// When non-empty, the aggregate is the max over exactly these keys and the
    /// groups are ignored. Used where the right inputs cut across groups.
    public let keys: Set<String>
    public let unit: SensorUnit

    public init(id: String, label: String, groups: Set<SensorGroup> = [],
                keys: Set<String> = [], unit: SensorUnit = .celsius) {
        self.id = id; self.label = label; self.groups = groups
        self.keys = keys; self.unit = unit
    }

    public static let all: [AggregateSensor] = [
        .init(id: "agg.cpu",     label: "CPU (hottest core)",
              groups: [.cpuPerformance, .cpuEfficiency]),
        // The sustained die temperature, not the instantaneous hottest core.
        //
        // `agg.cpu` is a max over every core sensor, so it follows TCMz — the
        // single hottest core — which swings by more than 20 C between samples
        // when one core briefly boosts. A curve bound to that chases transients
        // and hunts audibly. TCMb is the average die temperature, which is what
        // the heatsink actually has to remove, so it is the right input for a
        // ramp. Keep `agg.cpu` for the high thresholds where a genuine peak
        // matters.
        .init(id: "agg.cpuSustained", label: "CPU (sustained)", keys: ["TCMb"]),
        .init(id: "agg.pcore",   label: "CPU performance cores", groups: [.cpuPerformance]),
        .init(id: "agg.ecore",   label: "CPU efficiency cores",  groups: [.cpuEfficiency]),
        .init(id: "agg.gpu",     label: "GPU",           groups: [.gpu]),
        .init(id: "agg.soc",     label: "SoC",           groups: [.soc]),
        .init(id: "agg.memory",  label: "Memory",        groups: [.memory]),
        .init(id: "agg.storage", label: "SSD",           groups: [.storage]),
        .init(id: "agg.battery", label: "Battery",       groups: [.battery, .enclosureLower]),
        .init(id: "agg.power",   label: "Power delivery", groups: [.powerDelivery]),

        // Skin aggregates — the inputs the Cool profile exists to regulate.
        .init(id: "agg.skinUpper", label: "Top case (skin)",
              groups: [], keys: ["Ts0P", "Ts1P"]),
        .init(id: "agg.skinLower", label: "Bottom case (skin)",
              groups: [], keys: ["TB0T"]),
        .init(id: "agg.internalAir", label: "Internal airflow", groups: [.internalAir]),
        .init(id: "agg.roomAir",     label: "Room air",         groups: [.roomAir]),
    ]

    public static func named(_ id: String) -> AggregateSensor? {
        all.first { $0.id == id }
    }
}
