import Foundation

// Built-in multi-leg profiles.
//
// The two profiles answer different questions, and the difference is noise:
//
//   Smart — keep the machine cool WITHOUT being noisy.
//   Cool  — keep the machine cool, full stop. Noise is an acceptable price.
//
// What makes Smart "smart" is not a higher threshold, it is an earlier and
// gentler one. Heat that is never allowed to accumulate never has to be removed
// in a hurry, so a curve that starts at 70 C and rises slowly holds a lower
// steady-state temperature than one that waits for 88 C and then has to shout.
// Early-and-gentle is both cooler and quieter than late-and-loud; that is the
// whole idea. Smart's ceilings are therefore capped well below the fan's range
// so it can never become the thing you notice.
//
// Cool makes the opposite trade deliberately. It starts much earlier, ramps
// harder, holds a raised floor on AC, and is allowed most of the fan's range.
//
// Reference measurements on this class of machine, both fans in firmware auto:
// idle CPU 45-60 C, SoC ~62, GPU ~60, skin 32-35, system draw 12-20 W; moderate
// load 65-75 C at 27-35 W; heavy load 90-99 C at 40-50 W. Across ~380 s
// spanning a CPU hot-point of 98.9 C the firmware never raised either fan above
// its minimum -- it prefers to soak and throttle. Both profiles are therefore
// strictly more cooling than auto, and `FanEngine` additionally treats the
// firmware's own demand as a hard lower bound.

public extension Preset {

    /// Cool without the noise. The default choice for everyday use.
    static let smart = Preset(
        id: "builtin.smart",
        name: "Smart",
        isBuiltIn: true,
        modes: [:],
        fallback: .multi(legs: smartLegs)
    )

    /// Cool, unconditionally. Louder, and meant to be.
    static let cool = Preset(
        id: "builtin.cool",
        name: "Cool",
        isBuiltIn: true,
        modes: [:],
        fallback: .multi(legs: coolLegs)
    )

    /// r0 == 0 means "this fan's own minimum", resolved per fan at runtime.
    ///
    /// Ceilings here top out at 3800 rpm. That is the quietness budget: Smart is
    /// allowed to use the lower half of the fan's range and nothing more, so it
    /// can be running constantly without ever being the loudest thing in the
    /// room. If a leg genuinely needs more than 3800 rpm, the situation is no
    /// longer routine and the thermal backstop handles it.
    static var smartLegs: [FanCurveLeg] {
        [
            // Ramps on the SUSTAINED die temperature, not the hottest core.
            // Starts at 70 C -- inside the normal loaded band rather than above
            // it, which is the point. Idle is 45-60 C so the fan stays at its
            // minimum when nothing is happening. Binding this to the hottest
            // core instead makes the fan chase single-core boost transients,
            // which is precisely the noise Smart exists to avoid.
            //
            // Knees are on the SUSTAINED scale, which reads roughly 10-15 C
            // below the hottest core. Measured on this machine: quiet idle 60,
            // busy idle 64-71, sustained all-core load 71-82.
            //
            // 68/88 was tried first and was too timid to be worth running: it
            // held 1717 rpm through a load where the firmware peaked at 90.7 C
            // and Smart peaked at 91.3 C — quiet, but no cooler than Automatic,
            // which is a profile with no reason to exist. 62/80 keeps a
            // genuinely idle machine silent (60 is below the knee), a merely
            // busy one near-silent at ~1600, and puts ~2600 rpm under real load
            // where it can actually take heat out.
            .init(id: "cpu",       sensorID: "agg.cpuSustained", t0: 62, t1: 80, r0: 0, r1: 3800),
            // A genuine peak still matters, so keep a second leg on the hottest
            // core with a threshold high enough that transients never reach it.
            .init(id: "cpuPeak",   sensorID: "agg.cpu",       t0: 96, t1: 106, r0: 0, r1: 3800),
            .init(id: "soc",       sensorID: "agg.soc",       t0: 66, t1: 86, r0: 0, r1: 3600),
            .init(id: "gpu",       sensorID: "agg.gpu",       t0: 66, t1: 86, r0: 0, r1: 3600),
            .init(id: "memory",    sensorID: "agg.memory",    t0: 72, t1: 90, r0: 0, r1: 3400),
            // This group idles at ~65 C and normally sits near 75, so its knee
            // has to sit above that or the fan would never stop.
            .init(id: "power",     sensorID: "agg.power",     t0: 88, t1: 102, r0: 0, r1: 3400),
            // A sustained multi-hundred-GB write heats the NAND with almost no
            // CPU heat; a CPU-only curve is blind to it and firmware ignores it.
            .init(id: "ssd",       sensorID: "agg.storage",   t0: 56, t1: 72, r0: 0, r1: 3200),
            // Lithium ageing accelerates above ~40 C and the damage is
            // cumulative, unlike die heat. Charging alone triggers this with no
            // compute at all.
            .init(id: "battery",   sensorID: "agg.battery",   t0: 38, t1: 46, r0: 0, r1: 2800),
            // Comfort, gently. Sustained bare-skin contact with metal turns
            // unpleasant around 43 C, so this finishes before that.
            .init(id: "skinUpper", sensorID: "agg.skinUpper", t0: 40, t1: 48, r0: 0, r1: 3200),
            .init(id: "skinLower", sensorID: "agg.skinLower", t0: 38, t1: 46, r0: 0, r1: 3200),
        ]
    }

    /// Cool's own complete table. Every leg starts earlier, rises faster and is
    /// allowed further than its Smart counterpart, so Cool's demand is greater
    /// than Smart's at every input — asserted numerically in the self-test
    /// rather than assumed.
    ///
    /// Ceilings stop at 5400 of the fan's 5777, leaving the top of the range
    /// reserved so that "fans at absolute maximum" remains an unambiguous fault
    /// signal from the thermal backstop rather than a routine operating state.
    static var coolLegs: [FanCurveLeg] {
        [
            // Skin is what "cool to the touch" actually means, and these knees
            // sit only a couple of degrees above a comfortable idle (32-35 C) —
            // Cool starts working before the case is warm, not after.
            .init(id: "skinUpper", sensorID: "agg.skinUpper", t0: 34, t1: 42,
                  r0: coolFloorRPM, r1: 5200),
            // The bottom case rests on a lap with broad continuous contact and
            // no keyboard air gap, so it gets the tighter knee of the two.
            .init(id: "skinLower", sensorID: "agg.skinLower", t0: 33, t1: 40,
                  r0: coolFloorRPM, r1: 5200),
            // Feed-forward. Skin has roughly a 92 s time constant and keeps
            // climbing after the load that caused it has stopped, so a purely
            // reactive profile spins up about a minute after the user's hands
            // are already warm. System power leads skin by ~40 s and moves
            // within 1-2 s of load onset. Measured idle draw is 12-20 W, so a
            // 15 W knee means Cool is already moving before heat reaches the
            // case at all.
            .init(id: "powerFF",   sensorID: "agg.systemPower", t0: 15, t1: 40,
                  r0: coolFloorRPM, r1: 5000),

            // Silicon legs, all far more aggressive than Smart's: Cool aims to
            // stop the machine getting hot rather than to stop it overheating.
            .init(id: "cpu",       sensorID: "agg.cpuSustained", t0: 55, t1: 82,
                  r0: coolFloorRPM, r1: 5400),
            .init(id: "cpuPeak",   sensorID: "agg.cpu",       t0: 78, t1: 98,
                  r0: coolFloorRPM, r1: 5400),
            .init(id: "soc",       sensorID: "agg.soc",       t0: 56, t1: 80,
                  r0: coolFloorRPM, r1: 5200),
            .init(id: "gpu",       sensorID: "agg.gpu",       t0: 56, t1: 80,
                  r0: coolFloorRPM, r1: 5200),
            .init(id: "memory",    sensorID: "agg.memory",    t0: 62, t1: 84,
                  r0: coolFloorRPM, r1: 5000),
            .init(id: "power",     sensorID: "agg.power",     t0: 76, t1: 96,
                  r0: coolFloorRPM, r1: 4800),
            .init(id: "ssd",       sensorID: "agg.storage",   t0: 48, t1: 66,
                  r0: coolFloorRPM, r1: 4600),
            .init(id: "battery",   sensorID: "agg.battery",   t0: 34, t1: 44,
                  r0: coolFloorRPM, r1: 4200),
        ]
    }

    /// At the fan minimum with the machine merely warm, the top case measures
    /// 46-48 C. A profile whose entire purpose is touch temperature cannot idle
    /// where a profile that ignores touch idles, so Cool holds ~24% of the
    /// usable range as its floor even when every input is cold.
    ///
    /// Dropped to the fan minimum on battery, where continuous fan power is not
    /// worth it and the machine runs cooler anyway — charging is itself a large
    /// heat source, measured at 66-94 W of adapter draw.
    static var coolFloorRPM: Double { 2400 }

    static let builtIns: [Preset] = [.auto, .smart, .cool, .fullBlast]
}

/// Thresholds that override any profile.
///
/// No profile leg reaches the fan's true maximum, so fans at absolute maximum
/// stays an unambiguous fault signal rather than a routine operating state.
public enum ThermalBackstop {
    public static let limits: [(sensorID: String, celsius: Double)] = [
        ("agg.cpu", 105), ("agg.soc", 100), ("agg.gpu", 100),
        ("agg.power", 108), ("agg.storage", 85), ("agg.battery", 55),
        ("agg.memory", 100),
    ]

    /// Must hold continuously for this long before the backstop fires, so a
    /// single bad sample cannot slam the fans to maximum.
    public static let dwell: TimeInterval = 5

    public static func breached(_ lookup: (String) -> Double?) -> String? {
        for (id, limit) in limits {
            if let v = lookup(id), v >= limit { return id }
        }
        return nil
    }
}
