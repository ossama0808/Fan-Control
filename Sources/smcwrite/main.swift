import SMCKitCore
import Foundation

// fancontrol-smcwrite — the only component that runs as root.
//
// Deliberately NOT a general "write any SMC key" service. It accepts a fan
// index and an RPM, and nothing else, so a compromised GUI cannot use it to
// poke arbitrary SMC keys. RPM is clamped to the fan's own hardware min/max
// read back from the SMC at write time.

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("smcwrite: " + msg + "\n").utf8))
    exit(1)
}

let args = CommandLine.arguments.dropFirst()
guard let verb = args.first else {
    fail("usage: smcwrite set <fan> <rpm> | setmulti <fan>:<rpm> ... | auto <fan> | auto-all | status")
}

let smc: SMC
do { smc = try SMC() } catch { fail("cannot open SMC: \(error)") }

func fanCount() -> Int {
    (try? smc.readDouble(SMCKey("FNum"))).map { Int($0) } ?? 0
}

func requireFan(_ s: String?) -> Int {
    guard let s, let i = Int(s), i >= 0, i < fanCount() else {
        fail("fan index out of range (have \(fanCount()) fans)")
    }
    return i
}

/// Write a Double to a key using whatever type the SMC declares for it.
func write(_ key: String, _ value: Double) throws {
    let k = SMCKey(key)
    let info = try smc.keyInfo(k)
    let bytes = try SMC.encode(value, type: info.dataType, size: info.dataSize)
    try smc.writeRaw(k, bytes: bytes)
}

/// Bring the fans out of the firmware's powered-down state.
///
/// When the Mac is cool the firmware switches the fans off entirely and reports
/// mode 3. In that state `F<n>Md` is not writable — every attempt returns SMC
/// result 130, in any order and however many times it is retried.
///
/// Writing `Ftst` releases them. Traced from a known-good implementation and
/// then reproduced from scratch: a single `Ftst = 1` moves the fan out of mode 3
/// and the firmware spins it up. (`Frqd` looks like the matching control but is
/// read-only, result 134.)
///
/// Returns true if it had to wake the fans, because the caller must then expect
/// the mode write to fail. The firmware does not accept one until it has the
/// fans actually turning, which measures around six seconds — far too long to
/// block here. The caller re-asserts twice a second, so the tick that lands
/// after the fans are up takes control with nothing extra to do.
@discardableResult
func releaseFansFromStandby() -> Bool {
    let off = (0..<fanCount()).contains { i in
        ((try? smc.readDouble(SMCKey("F\(i)Md"))) ?? 0) == 3
    }
    guard off else { return false }
    try? smc.writeRaw(SMCKey("Ftst"), bytes: [1])
    return true
}

/// Hand the fans back, including the ability to switch themselves off.
///
/// Leaving `Ftst` set keeps them turning at their minimum forever, so a cool
/// machine would never go quiet again. Only cleared once nothing is being
/// driven, so releasing one fan does not strand another.
func restoreStandbyIfIdle() {
    let anyManual = (0..<fanCount()).contains { i in
        ((try? smc.readDouble(SMCKey("F\(i)Md"))) ?? 0) == 1
    }
    guard !anyManual else { return }
    try? smc.writeRaw(SMCKey("Ftst"), bytes: [0])
}

func setFan(_ i: Int, rpm: Double, quiet: Bool = false) throws {
    let lo = try smc.readDouble(SMCKey("F\(i)Mn"))
    let hi = try smc.readDouble(SMCKey("F\(i)Mx"))
    let clamped = min(max(rpm, lo), hi)
    let waking = releaseFansFromStandby()
    do {
        try write("F\(i)Md", 1)          // manual mode
        try write("F\(i)Tg", clamped)    // target rpm
    } catch {
        // Expected for a few seconds after waking the fans; not a failure.
        if waking {
            if !quiet { print("fan \(i) -> waking (firmware is spinning it up)") }
            return
        }
        throw error
    }
    if !quiet {
        print(String(format: "fan %d -> manual %.0f rpm (clamped to %.0f..%.0f)", i, clamped, lo, hi))
    }
}

func autoFan(_ i: Int) throws {
    try write("F\(i)Md", 0)
    restoreStandbyIfIdle()
    print("fan \(i) -> auto")
}

do {
    switch verb {
    case "set":
        let i = requireFan(args.dropFirst().first)
        guard let r = args.dropFirst(2).first, let rpm = Double(r) else { fail("bad rpm") }
        try setFan(i, rpm: rpm)
    case "setmulti":
        // Apple Silicon expires manual fan mode after ~2-3s, so the app must
        // re-assert every target continuously. Taking all fans in one call
        // keeps that refresh to a single process spawn per tick.
        var applied = 0
        for pair in args.dropFirst() {
            let parts = pair.split(separator: ":")
            guard parts.count == 2, let i = Int(parts[0]), let rpm = Double(parts[1]),
                  i >= 0, i < fanCount() else { fail("bad pair '\(pair)'") }
            try setFan(i, rpm: rpm)
            applied += 1
        }
        if applied == 0 { fail("setmulti needs at least one <fan>:<rpm>") }
    case "auto":
        try autoFan(requireFan(args.dropFirst().first))
    case "auto-all":
        for i in 0..<fanCount() { try autoFan(i) }
    case "status":
        let n = fanCount()
        print("fans: \(n)  (uid=\(getuid()) euid=\(geteuid()))")
        for i in 0..<n {
            let ac = (try? smc.readDouble(SMCKey("F\(i)Ac"))) ?? -1
            let tg = (try? smc.readDouble(SMCKey("F\(i)Tg"))) ?? -1
            let md = (try? smc.readDouble(SMCKey("F\(i)Md"))) ?? -1
            let mn = (try? smc.readDouble(SMCKey("F\(i)Mn"))) ?? -1
            let mx = (try? smc.readDouble(SMCKey("F\(i)Mx"))) ?? -1
            print(String(format: "  fan %d: %.0f rpm  target %.0f  mode %@  range %.0f..%.0f",
                         i, ac, tg, md == 1 ? "MANUAL" : "auto", mn, mx))
        }
    default:
        fail("unknown command '\(verb)'")
    }
} catch {
    fail("\(error)")
}
