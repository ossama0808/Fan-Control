import Foundation

/// Talks to the setuid-root `smcwrite` helper.
///
/// Every privileged operation the app can perform is expressed here, and the
/// helper's own argument parser is the enforcement point: it accepts a fan
/// index and an RPM, never a raw SMC key, so this channel cannot be used to
/// write arbitrary hardware registers.
public final class HelperClient: @unchecked Sendable {

    public static let helperPath = "/usr/local/libexec/fancontrol-smcwrite"

    /// Privileged writes run here, never on the main actor.
    ///
    /// Each call spawns the helper process, which measures 74-100 ms. Done
    /// synchronously on the main actor twice a second that is ~20% of the actor's
    /// time, and it delays the very timer that renews the fan lease — the fan
    /// then drops back to firmware. Writes are therefore dispatched here and the
    /// caller does not wait.
    private let queue = DispatchQueue(label: "com.local.fancontrol.helper",
                                      qos: .userInitiated)
    private let busy = NSLock()
    private var writing = false

    public enum Status: Equatable {
        case ready
        case notInstalled
        case notPrivileged   // installed but missing setuid bit
    }

    public init() {}

    public func status() -> Status {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: Self.helperPath) else {
            return .notInstalled
        }
        let owner = attrs[.ownerAccountID] as? NSNumber
        let perms = attrs[.posixPermissions] as? NSNumber
        let isSetuid = (perms?.uint16Value ?? 0) & 0o4000 != 0
        return (owner?.intValue == 0 && isSetuid) ? .ready : .notPrivileged
    }

    @discardableResult
    private func run(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.helperPath)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "FanControl.Helper", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey:
                                     String(decoding: e, as: UTF8.self)])
        }
        return String(decoding: o, as: UTF8.self)
    }

    /// Fire-and-forget batched write.
    ///
    /// If a previous write is still running the tick is DROPPED rather than
    /// queued: the next tick is only half a second away and carries a target
    /// that is at least as current, so queueing would only build latency.
    public func setFansAsync(_ targets: [Int: Double],
                             releasing: [Int] = [],
                             onError: @escaping @Sendable (String) -> Void) {
        busy.lock()
        if writing { busy.unlock(); return }
        writing = true
        busy.unlock()

        queue.async { [self] in
            defer { busy.lock(); writing = false; busy.unlock() }
            do {
                for i in releasing { try setAuto(i) }
                if !targets.isEmpty { try setFans(targets) }
            } catch {
                onError(error.localizedDescription)
            }
        }
    }

    public func setFan(_ index: Int, rpm: Double) throws {
        try run(["set", "\(index)", String(format: "%.0f", rpm)])
    }

    /// Apply several fan targets in one privileged call.
    public func setFans(_ targets: [Int: Double]) throws {
        guard !targets.isEmpty else { return }
        try run(["setmulti"] + pairArgs(targets))
    }

    private func pairArgs(_ targets: [Int: Double]) -> [String] {
        targets.sorted { $0.key < $1.key }
               .map { String(format: "%d:%.0f", $0.key, $0.value) }
    }

    public func setAuto(_ index: Int) throws {
        try run(["auto", "\(index)"])
    }

    public func setAllAuto() throws {
        try run(["auto-all"])
    }
}
