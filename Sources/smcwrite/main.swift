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

func setFan(_ i: Int, rpm: Double, quiet: Bool = false) throws {
    let lo = try smc.readDouble(SMCKey("F\(i)Mn"))
    let hi = try smc.readDouble(SMCKey("F\(i)Mx"))
    let clamped = min(max(rpm, lo), hi)
    try write("F\(i)Md", 1)          // manual mode
    try write("F\(i)Tg", clamped)    // target rpm
    if !quiet {
        print(String(format: "fan %d -> manual %.0f rpm (clamped to %.0f..%.0f)", i, clamped, lo, hi))
    }
}

func autoFan(_ i: Int) throws {
    try write("F\(i)Md", 0)
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
