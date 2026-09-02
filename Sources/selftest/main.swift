import Foundation
import FanControlKit
import SMCKitCore

setvbuf(stdout, nil, _IONBF, 0)   // keep diagnostics when an assert aborts

// Runnable check for the one piece of logic that is easy to get silently wrong:
// the SMC's manual-mode lease expires, so FanEngine must keep re-asserting.
// Failure mode this catches: fans quietly revert to firmware auto while the UI
// still claims they are under manual control.

/// Spin the main run loop for `seconds`. FanEngine schedules its timers on
/// RunLoop.main (as it must, to match the app), so a plain Task.sleep would
/// starve them and this check would fail for the wrong reason.
@MainActor
func pump(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

@MainActor
func main() throws {
    // 1. Pure curve maths — no hardware needed.
    let curve = FanMode.sensorBased(sensorID: "agg.cpu", minTemp: 50, maxTemp: 90,
                                    minRPM: 1000, maxRPM: 5000)
    assert(curve.targetRPM(temperature: 40) == 1000, "below range should pin to minRPM")
    assert(curve.targetRPM(temperature: 100) == 5000, "above range should pin to maxRPM")
    assert(curve.targetRPM(temperature: 70) == 3000, "midpoint should interpolate")
    // A dead sensor must fail loud (full speed), never silently idle.
    assert(curve.targetRPM(temperature: nil) == 5000, "unreadable sensor must go max")
    assert(curve.targetRPM(temperature: 0) == 5000, "parked sensor must go max")
    assert(FanMode.auto.targetRPM(temperature: 60) == nil, "auto commands nothing")
    print("✓ curve maths")

    // 1b. Multi-leg profiles: the semantics that differ from a single curve.
    let hot = FanCurveLeg(id: "hot", sensorID: "a", t0: 80, t1: 100, r0: 0, r1: 5000)
    let cold = FanCurveLeg(id: "cold", sensorID: "b", t0: 40, t1: 50, r0: 2400, r1: 4000)
    let multi = FanMode.multi(legs: [hot, cold])

    // r0 == 0 resolves to the fan's own minimum, so one table fits any fan.
    assert(hot.floor(fanMinimum: 1350) == 1350, "zero floor must resolve to fan minimum")
    assert(cold.floor(fanMinimum: 1350) == 2400, "explicit floor must be kept")

    // The fan follows whichever leg is asking for the most air.
    let d1 = multi.demand(fanMinimum: 1350) { $0 == "a" ? 90 : 40 }
    assert(d1?.dominantLegID == "hot", "hottest-demand leg must win")
    assert(abs((d1?.rpm ?? 0) - 3175) < 1, "expected midpoint of the hot leg, got \(d1?.rpm ?? -1)")

    // A single dead leg is SKIPPED, not forced to maximum. Forcing max here is
    // the bug that would pin both fans forever whenever one group went dark.
    let d2 = multi.demand(fanMinimum: 1350) { $0 == "a" ? nil : 45 }
    assert(d2?.blind == false, "one dead leg must not blind the profile")
    assert(d2?.dominantLegID == "cold", "surviving leg must drive")

    // Losing EVERY leg is a real fault and must fail loud.
    let d3 = multi.demand(fanMinimum: 1350) { _ in nil }
    assert(d3?.blind == true, "all legs dead must report blind")
    print("✓ multi-leg demand: max wins, one dead leg skipped, all dead fails loud")

    // 1c. Cool must never be gentler than Smart, at ANY input.
    //
    // The two profiles now have independent leg tables, so a structural check
    // ("Cool contains Smart's legs") no longer proves anything. Sweep the whole
    // plausible input space and compare demands directly.
    let smartMode = Preset.smart.fallback
    let coolMode = Preset.cool.fallback
    let fanMin = 1350.0
    var worstGap = Double.infinity
    var checked = 0
    for temp in stride(from: 20.0, through: 110.0, by: 2.0) {
        for watts in stride(from: 5.0, through: 60.0, by: 5.0) {
            let lookup: (String) -> Double? = { id in id == "agg.systemPower" ? watts : temp }
            guard let sd = smartMode.demand(fanMinimum: fanMin, lookup: lookup),
                  let cd = coolMode.demand(fanMinimum: fanMin, lookup: lookup) else { continue }
            worstGap = min(worstGap, cd.rpm - sd.rpm)
            checked += 1
        }
    }
    assert(checked > 500, "sweep did not run")
    assert(worstGap >= 0,
           String(format: "Cool demands %.0f rpm LESS than Smart somewhere in the input space", -worstGap))
    print(String(format: "✓ Cool >= Smart across %d input combinations (tightest margin %.0f rpm)",
                 checked, worstGap))

    // Smart's quietness budget is the whole reason it is a separate profile.
    let smartCeiling = Preset.smartLegs.map(\.r1).max() ?? 0
    assert(smartCeiling <= 3800,
           String(format: "Smart may not exceed its 3800 rpm quiet budget (found %.0f)", smartCeiling))
    // And Smart must idle silently: every leg falls back to the fan minimum.
    assert(Preset.smartLegs.allSatisfy { $0.r0 == 0 },
           "Smart must idle at the fan minimum, not a raised floor")
    // Cool must NOT idle silently: a raised floor is its defining behaviour.
    assert(Preset.coolLegs.allSatisfy { $0.r0 == Preset.coolFloorRPM },
           "every Cool leg must hold the raised floor")
    print(String(format: "✓ Smart caps at %.0f rpm and idles silent; Cool floors at %.0f rpm",
                 smartCeiling, Preset.coolFloorRPM))

    // 1d. Structurally fake readings must be rejected. Six keys reading exactly
    // 9.10 sit inside every sane temperature band and are indistinguishable
    // from real readings except that they agree bit-exactly.
    let fakeRows = (0..<6).map {
        (sensor: Sensor(key: "Ta0\($0)", group: .internalAir, label: "x"), celsius: 9.10)
    }
    let realRows = [
        (sensor: Sensor(key: "TaTP", group: .internalAir, label: "y"), celsius: 58.1),
        (sensor: Sensor(key: "TaLP", group: .internalAir, label: "z"), celsius: 41.3),
    ]
    let rejected = SensorCatalog.rejectingFakes(fakeRows + realRows)
    assert(rejected.count == 6, "expected the 6 identical constants rejected, got \(rejected.count)")
    assert(!rejected.contains("TaTP") && !rejected.contains("TaLP"),
           "real independent readings must survive")
    print("✓ fake-sensor rejection")

    // 1e. Group bands, not one global band. 40.0 is a normal enclosure reading
    // and also exactly what a power-gated core reports.
    assert(SensorCatalog.isLive(40, group: .enclosureUpper), "40C is a real case temperature")
    assert(!SensorCatalog.isLive(3.4, group: .cpuPerformance), "a gated core must read as dead")
    assert(!SensorCatalog.isLive(95, group: .battery), "95C is not a plausible battery temp")
    print("✓ per-group plausibility bands")

    // 1e2. A fan's range must be well-formed even when a hardware read failed.
    // minRPM and maxRPM come from separate SMC reads; a single failure yields 0,
    // and `1350...0` is not a bad value in Swift, it is an immediate trap that
    // takes the app down. This is the guard against that.
    let brokenHigh = FanState(index: 0, currentRPM: 0, targetRPM: 0,
                              minRPM: 1350, maxRPM: 0, hardwareMode: .auto)
    let brokenBoth = FanState(index: 0, currentRPM: 0, targetRPM: 0,
                              minRPM: 0, maxRPM: 0, hardwareMode: .off)
    let normal = FanState(index: 0, currentRPM: 2000, targetRPM: 2000,
                          minRPM: 1350, maxRPM: 5777, hardwareMode: .manual)
    for f in [brokenHigh, brokenBoth, normal] {
        let r = f.rpmRange
        assert(r.lowerBound <= r.upperBound,
               "rpmRange must never be reversed (min \(f.minRPM), max \(f.maxRPM))")
        // Must also be usable as a clamp target without trapping.
        _ = 3000.0.clamped(to: r)
    }
    assert(normal.rpmRange == 1350...5777, "a healthy fan must keep its real range")
    print("✓ fan range stays well-formed when a hardware read fails")

    // 1f. The backstop must sit above every profile ceiling, so "fans at
    // absolute maximum" stays an unambiguous fault signal.
    let maxLegCeiling = (Preset.smartLegs + Preset.coolLegs).map(\.r1).max() ?? 0
    assert(maxLegCeiling < 5777, "no profile leg may reach the fan's true maximum")
    assert(maxLegCeiling <= 5400, "leave headroom so max rpm stays a fault signal")
    assert(ThermalBackstop.breached { _ in 200 } != nil, "an absurd temperature must trip the backstop")
    assert(ThermalBackstop.breached { _ in 50 } == nil, "normal temperatures must not trip it")
    print("✓ thermal backstop reserved above profile ceilings")

    // 2. Live hardware: does a target actually survive the SMC's lease timeout?
    let engine = try FanEngine()
    guard engine.helperStatus == .ready else {
        print("! helper not installed — skipping hardware assertion test")
        return
    }
    guard let fan = engine.fans.first else { print("! no fans"); return }
    // A cool Mac has its fans powered off by the firmware, and nothing can drive
    // them in that state. Skip rather than fail: the release script gates on
    // this test, and a cold machine is not a broken build.
    guard !engine.fans.allSatisfy(\.isPoweredOff) else {
        print("! fans are powered off by the firmware (mode 3) — skipping hardware checks.")
        print("  Warm the machine up and re-run to exercise them.")
        print("\nLOGIC CHECKS PASSED (hardware checks skipped)")
        return
    }

    let target = min(fan.minRPM + 900, fan.maxRPM)
    print("setting \(fan.name) to \(Int(target)) rpm, holding for 12s…")
    engine.setMode(.constant(rpm: target), for: fan.index)
    engine.start()

    // What counts as "in control" needs care. Two effects are real and neither
    // is a bug:
    //  - the mode bit reads 0 transiently between a lease lapsing and the next
    //    assertion landing;
    //  - on a warm machine the firmware periodically reclaims a fan for a single
    //    sample even when writes are landing continuously. Verified with a bare
    //    shell loop and no engine at all, and writing every 150 ms instead of
    //    every 500 ms did not reduce it — so it is firmware behaviour, not a gap
    //    we leave.
    // The failure that matters is SUSTAINED loss: if the assertion loop stops,
    // the firmware holds the fan and never gives it back. So assert on
    // consecutive losses, plus that the fan actually tracks the commanded speed.
    var lostControl = 0
    var consecutiveLost = 0, worstConsecutive = 0
    var observedRPM: [Double] = []
    for i in 1...12 {
        pump(1)
        engine.refresh()
        guard let f = engine.fans.first(where: { $0.index == fan.index }) else { continue }
        let ours = abs(f.targetRPM - target) < 50
        if ours { consecutiveLost = 0 } else {
            lostControl += 1
            consecutiveLost += 1
            worstConsecutive = max(worstConsecutive, consecutiveLost)
        }
        observedRPM.append(f.currentRPM)
        print(String(format: "  t=%2ds  %.0f rpm  target %.0f  %@%@",
                     i, f.currentRPM, f.targetRPM,
                     f.hardwareIsManual ? "MANUAL" : "auto",
                     ours ? "" : "   <-- FIRMWARE RETOOK THE FAN"))
    }

    // 3. Releasing must actually reach the hardware. A fan left in manual by a
    // process that has exited can stay pinned indefinitely, so this is the
    // check that matters most after the hold test.
    engine.setMode(.auto, for: fan.index)
    pump(2)
    engine.refresh()
    let released = engine.fans.first { $0.index == fan.index }
    assert(released?.hardwareIsManual == false,
           "fan still reports manual after being set back to auto — release path is broken")
    print("✓ released back to firmware control")

    // 4. The profiles must actually drive the hardware, and Cool must be the
    // more aggressive of the two. This is the end-to-end check that the leg
    // tables, aggregate lookup and helper path are all wired together.
    for preset in [Preset.smart, Preset.cool] {
        engine.applyPreset(preset)
        pump(4)
        engine.refresh()
        let rpm = engine.fans.map(\.currentRPM)
        let legs = engine.fans.compactMap { engine.dominantLeg[$0.index] }
        print(String(format: "  %@: %@ rpm  driving leg(s): %@", preset.name,
                     rpm.map { String(format: "%.0f", $0) }.joined(separator: "/"),
                     legs.isEmpty ? "none" : legs.joined(separator: ",")))
        if preset.id == Preset.cool.id, engine.onACPower {
            // Cool holds a raised floor on AC; that is its entire point.
            let target = engine.fans.map(\.targetRPM).min() ?? 0
            assert(target >= Preset.coolFloorRPM - 100,
                   String(format: "Cool commanded only %.0f rpm, below its %.0f floor",
                          target, Preset.coolFloorRPM))
        }
    }
    print("✓ Smart and Cool drive the hardware")

    // 4b. A profile must be able to spin DOWN, not just up. The deadband and the
    // ramp limiter interact: if the deadband is applied to the ramp-limited step
    // rather than to the demand, every descent (40 rpm/tick) is smaller than the
    // deadband (60 rpm) and gets swallowed, pinning the fan at its high-water
    // mark forever. Drive it high, then drop the demand and watch it come back.
    engine.setMode(.constant(rpm: min(fan.minRPM + 2500, fan.maxRPM)), for: fan.index)
    pump(6)
    engine.refresh()
    let high = engine.fans.first { $0.index == fan.index }?.targetRPM ?? 0
    engine.setMode(.constant(rpm: fan.minRPM + 200), for: fan.index)
    pump(20)
    engine.refresh()
    let low = engine.fans.first { $0.index == fan.index }?.targetRPM ?? 0
    print(String(format: "  ramp down: %.0f -> %.0f rpm", high, low))
    assert(low < high - 500,
           String(format: "fan did not spin down: still %.0f rpm after commanding %.0f (was %.0f)",
                  low, fan.minRPM + 200, high))
    print("✓ profiles can ramp down, not just up")

    engine.applyPreset(.auto)
    pump(2)
    engine.stop()
    engine.restoreAutoOnExit()
    pump(2)
    engine.refresh()
    assert(engine.fans.allSatisfy { !$0.hardwareIsManual },
           "restoreAutoOnExit left a fan in manual mode")
    print("✓ restoreAutoOnExit released every fan")

    // The lease expires in ~3s, so any lapse in re-assertion shows up as an
    // "auto" sample well before 12 seconds are up.
    let meanRPM = observedRPM.reduce(0, +) / Double(max(1, observedRPM.count))
    let trackingError = abs(meanRPM - target) / target

    assert(worstConsecutive < 3,
           "firmware held the fan for \(worstConsecutive) consecutive samples — the assertion loop has stopped renewing the lease")
    assert(trackingError < 0.15,
           String(format: "fan averaged %.0f rpm against a %.0f rpm command (%.0f%% off) — not actually under control",
                  meanRPM, target, trackingError * 100))
    print(String(format: "✓ held the fan: mean %.0f rpm vs %.0f commanded (%.1f%% error), %d/12 transient losses, worst streak %d",
                 meanRPM, target, trackingError * 100, lostControl, worstConsecutive))
    print("\nALL CHECKS PASSED")
}

try MainActor.assumeIsolated { try main() }
