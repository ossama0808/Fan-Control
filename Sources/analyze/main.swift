import Foundation
import FanControlKit
import SMCKitCore

// Profile analyser.
//
//   swift run analyze <auto|smart|cool|all> [seconds]
//
// Runs a profile through a fixed load pattern and reports what it actually did.
// Idle numbers prove nothing about a fan curve, so each run is 25% baseline,
// 50% all-core load, 25% recovery. Quit the app first — it drives the same fans.

setvbuf(stdout, nil, _IONBF, 0)

struct Sample {
    let t: TimeInterval
    let phase: String
    let fan0: Double, fan1: Double, target: Double
    let cpu: Double, soc: Double, gpu: Double
    let skinUp: Double, skinLow: Double, battery: Double
    let watts: Double
    let leg: String
}

@MainActor
func pump(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

/// In-process load at userInteractive QoS.
///
/// Spawning `yes` processes does not work: children inherit the parent's
/// background QoS, so the scheduler parks them on efficiency cores where they
/// burn 1300% CPU while moving the die under 1 C and system power by 3 W. Real
/// P-core load needs high-QoS threads in this process — measured effect is
/// TCMb 71 -> 83 C and 31 -> 46 W. Threads also cannot leak the way stray child
/// processes did, which silently poisoned earlier baselines.
final class Burner {
    private var stopped = false
    private let lock = NSLock()
    private func running() -> Bool { lock.lock(); defer { lock.unlock() }; return !stopped }
    func start(_ n: Int) {
        for _ in 0..<n {
            let t = Thread {
                var x = 0.0, i = 0.0
                while self.running() {
                    x += (i * 1.000001).squareRoot(); i += 1
                    if i > 1e9 { i = 0 }
                }
                if x == .infinity { print("") }
            }
            t.qualityOfService = .userInteractive
            t.start()
        }
    }
    func halt() { lock.lock(); stopped = true; lock.unlock() }
}

func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0,+) / Double(xs.count) }

@MainActor
func analyse(_ preset: Preset, seconds: Double, engine: FanEngine) -> [Sample] {
    print("\n\(String(repeating: "=", count: 66))")
    print("  \(preset.name.uppercased())  —  \(Int(seconds))s")
    print(String(repeating: "=", count: 66))

    engine.applyPreset(preset)
    pump(3)

    let baseline = seconds * 0.25, load = seconds * 0.5
    var samples: [Sample] = []
    let start = Date()
    let burner = Burner()
    var loadStarted = false, loadStopped = false

    print("  time  phase     fan0  fan1  target |  cpu   soc   gpu  skinU skinL  bat |  W   driving")
    while Date().timeIntervalSince(start) < seconds {
        let t = Date().timeIntervalSince(start)
        let phase = t < baseline ? "idle" : (t < baseline + load ? "LOAD" : "cool")

        if phase == "LOAD" && !loadStarted {
            burner.start(ProcessInfo.processInfo.activeProcessorCount); loadStarted = true
        }
        if phase == "cool" && !loadStopped { burner.halt(); loadStopped = true }

        pump(2)
        engine.refresh()

        let f = engine.fans
        let s = Sample(
            t: t, phase: phase,
            fan0: f.first?.currentRPM ?? 0, fan1: f.count > 1 ? f[1].currentRPM : 0,
            target: f.first?.targetRPM ?? 0,
            cpu: engine.temperature(forSensorID: "agg.cpu") ?? 0,
            soc: engine.temperature(forSensorID: "agg.soc") ?? 0,
            gpu: engine.temperature(forSensorID: "agg.gpu") ?? 0,
            skinUp: engine.temperature(forSensorID: "agg.skinUpper") ?? 0,
            skinLow: engine.temperature(forSensorID: "agg.skinLower") ?? 0,
            battery: engine.temperature(forSensorID: "agg.battery") ?? 0,
            watts: engine.temperature(forSensorID: "agg.systemPower") ?? 0,
            leg: engine.dominantLeg[0] ?? "-")
        samples.append(s)

        if samples.count % 3 == 0 {
            print(String(format: " %4.0fs  %-6@  %5.0f %5.0f  %5.0f | %5.1f %5.1f %5.1f %5.1f %5.1f %5.1f | %3.0f  %@",
                         s.t, s.phase, s.fan0, s.fan1, s.target,
                         s.cpu, s.soc, s.gpu, s.skinUp, s.skinLow, s.battery, s.watts, s.leg))
        }
    }
    burner.halt()
    engine.applyPreset(.auto)
    pump(4)
    return samples
}

func report(_ name: String, _ s: [Sample]) {
    let loadPhase = s.filter { $0.phase == "LOAD" }
    let idlePhase = s.filter { $0.phase == "idle" }
    print("\n  --- \(name) summary ---")
    print(String(format: "   idle:  fan %.0f rpm   cpu %.1fC  skinUp %.1fC  skinLow %.1fC",
                 mean(idlePhase.map(\.fan0)), mean(idlePhase.map(\.cpu)),
                 mean(idlePhase.map(\.skinUp)), mean(idlePhase.map(\.skinLow))))
    print(String(format: "   LOAD:  fan %.0f rpm (peak %.0f)  cpu %.1fC (peak %.1f)  skinUp %.1fC (peak %.1f)  skinLow %.1fC",
                 mean(loadPhase.map(\.fan0)), loadPhase.map(\.fan0).max() ?? 0,
                 mean(loadPhase.map(\.cpu)), loadPhase.map(\.cpu).max() ?? 0,
                 mean(loadPhase.map(\.skinUp)), loadPhase.map(\.skinUp).max() ?? 0,
                 mean(loadPhase.map(\.skinLow))))
    var legs: [String: Int] = [:]
    for x in s where x.leg != "-" { legs[x.leg, default: 0] += 1 }
    let hist = legs.sorted { $0.value > $1.value }
                   .map { "\($0.key) \(Int(Double($0.value) / Double(max(1,s.count)) * 100))%" }
    print("   driving legs: \(hist.isEmpty ? "none (auto)" : hist.joined(separator: ", "))")
}

let which = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "all"
let secs = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2])! : 180

try MainActor.assumeIsolated {
    let engine = try FanEngine()
    engine.start()
    guard engine.helperStatus == .ready else { print("helper not installed"); exit(1) }

    var chosen: [Preset] = []
    switch which {
    case "auto": chosen = [.auto]
    case "smart": chosen = [.smart]
    case "cool": chosen = [.cool]
    default: chosen = [.auto, .smart, .cool]
    }

    var all: [(String, [Sample])] = []
    for p in chosen {
        let s = analyse(p, seconds: secs, engine: engine)
        all.append((p.name, s))
        report(p.name, s)
        if p.id != chosen.last?.id {
            print("\n  (cooling down 45s before the next profile)")
            pump(45)
        }
    }

    print("\n\(String(repeating: "=", count: 66))")
    print("  COMPARISON (load phase)")
    print(String(repeating: "=", count: 66))
    print("  profile     fan rpm   peak cpu   peak skinUp   peak skinLow")
    for (name, s) in all {
        let l = s.filter { $0.phase == "LOAD" }
        print(String(format: "  %-10@  %7.0f   %8.1f   %11.1f   %12.1f",
                     name, mean(l.map(\.fan0)), l.map(\.cpu).max() ?? 0,
                     l.map(\.skinUp).max() ?? 0, l.map(\.skinLow).max() ?? 0))
    }

    engine.stop()
    engine.restoreAutoOnExit()
    print("\nfans restored to auto")
}
