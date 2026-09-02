import Foundation
import IOKit

// MARK: - Raw AppleSMC user-client ABI
// Layout must match the kernel's SMCParamStruct exactly or every call returns garbage.

struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

typealias SMCBytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                      UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                      UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                      UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

let zeroBytes: SMCBytes = (0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
                           0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0)

struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = zeroBytes
}

enum SMCSelector: UInt8 {
    case readKey = 5
    case writeKey = 6
    case getKeyFromIndex = 8
    case getKeyInfo = 9
}

// MARK: - Key / type helpers

/// A 4-character SMC key ("F0Ac") packed into the big-endian UInt32 the SMC expects.
public struct SMCKey: Hashable, CustomStringConvertible {
    public let code: UInt32
    public init(_ s: String) {
        var v: UInt32 = 0
        for b in s.utf8.prefix(4) { v = (v << 8) | UInt32(b) }
        self.code = v
    }
    public init(code: UInt32) { self.code = code }
    public var description: String {
        let b = [UInt8(truncatingIfNeeded: code >> 24), UInt8(truncatingIfNeeded: code >> 16),
                 UInt8(truncatingIfNeeded: code >> 8), UInt8(truncatingIfNeeded: code)]
        return String(decoding: b, as: UTF8.self)
    }
}

public struct SMCKeyInfo {
    public let dataSize: UInt32
    public let dataType: String
}

public enum SMCError: Error, CustomStringConvertible {
    case driverNotFound
    case failedToOpen(kern_return_t)
    case notOpen
    case callFailed(kern_return_t)
    case smcError(UInt8)        // non-zero `result` byte from the SMC
    case keyNotFound(String)
    case unsupportedType(String)

    public var description: String {
        switch self {
        case .driverNotFound: return "AppleSMC service not found"
        case .failedToOpen(let k): return "IOServiceOpen failed: 0x\(String(k, radix: 16))"
        case .notOpen: return "SMC connection not open"
        case .callFailed(let k): return "IOConnectCallStructMethod failed: 0x\(String(k, radix: 16))"
        case .smcError(let r): return "SMC returned result byte \(r)"
        case .keyNotFound(let k): return "SMC key not found: \(k)"
        case .unsupportedType(let t): return "unsupported SMC data type: \(t)"
        }
    }
}

// MARK: - Connection

public final class SMC {
    private var conn: io_connect_t = 0
    private var infoCache: [UInt32: SMCKeyInfo] = [:]

    public init() throws {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                             IOServiceMatching("AppleSMC"))
        guard svc != 0 else { throw SMCError.driverNotFound }
        defer { IOObjectRelease(svc) }
        let r = IOServiceOpen(svc, mach_task_self_, 0, &conn)
        guard r == kIOReturnSuccess else { throw SMCError.failedToOpen(r) }
    }

    deinit { if conn != 0 { IOServiceClose(conn) } }

    private func call(_ input: inout SMCParamStruct) throws -> SMCParamStruct {
        guard conn != 0 else { throw SMCError.notOpen }
        var output = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.stride
        let r = IOConnectCallStructMethod(conn, 2, &input,
                                          MemoryLayout<SMCParamStruct>.stride,
                                          &output, &outSize)
        guard r == kIOReturnSuccess else { throw SMCError.callFailed(r) }
        guard output.result == 0 else { throw SMCError.smcError(output.result) }
        return output
    }

    // MARK: Key enumeration

    public func keyInfo(_ key: SMCKey) throws -> SMCKeyInfo {
        if let c = infoCache[key.code] { return c }
        var input = SMCParamStruct()
        input.key = key.code
        input.data8 = SMCSelector.getKeyInfo.rawValue
        let out = try call(&input)
        let info = SMCKeyInfo(dataSize: out.keyInfo.dataSize,
                              dataType: SMCKey(code: out.keyInfo.dataType).description)
        infoCache[key.code] = info
        return info
    }

    public func keyCount() throws -> UInt32 {
        let d = try readRaw(SMCKey("#KEY"))
        return d.bytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    }

    public func key(at index: UInt32) throws -> SMCKey {
        var input = SMCParamStruct()
        input.data8 = SMCSelector.getKeyFromIndex.rawValue
        input.data32 = index
        let out = try call(&input)
        return SMCKey(code: out.key)
    }

    public func allKeys() throws -> [SMCKey] {
        let n = try keyCount()
        var keys: [SMCKey] = []
        keys.reserveCapacity(Int(n))
        for i in 0..<n {
            if let k = try? key(at: i) { keys.append(k) }
        }
        return keys
    }

    // MARK: Raw read / write

    public struct RawValue {
        public let bytes: [UInt8]
        public let type: String
    }

    public func readRaw(_ key: SMCKey) throws -> RawValue {
        let info = try keyInfo(key)
        var input = SMCParamStruct()
        input.key = key.code
        input.keyInfo.dataSize = info.dataSize
        input.data8 = SMCSelector.readKey.rawValue
        let out = try call(&input)
        var buf = out.bytes
        let arr = withUnsafeBytes(of: &buf) { Array($0.prefix(Int(info.dataSize))) }
        return RawValue(bytes: arr, type: info.dataType)
    }

    public func writeRaw(_ key: SMCKey, bytes: [UInt8]) throws {
        let info = try keyInfo(key)
        var input = SMCParamStruct()
        input.key = key.code
        input.keyInfo.dataSize = info.dataSize
        input.data8 = SMCSelector.writeKey.rawValue
        withUnsafeMutableBytes(of: &input.bytes) { dst in
            for (i, b) in bytes.prefix(dst.count).enumerated() { dst[i] = b }
        }
        _ = try call(&input)
    }

    // MARK: Typed read

    /// Decode any SMC value we care about into a Double.
    public func readDouble(_ key: SMCKey) throws -> Double {
        let v = try readRaw(key)
        return try SMC.decode(v)
    }

    public static func decode(_ v: RawValue) throws -> Double {
        let b = v.bytes
        switch v.type {
        case "flt ":
            guard b.count >= 4 else { throw SMCError.unsupportedType(v.type) }
            let bits = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
            return Double(Float(bitPattern: bits))
        case "ui8 ", "flag":
            return b.isEmpty ? 0 : Double(b[0])
        case "ui16":
            guard b.count >= 2 else { throw SMCError.unsupportedType(v.type) }
            return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "ui32":
            guard b.count >= 4 else { throw SMCError.unsupportedType(v.type) }
            return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        case "si8 ":
            return b.isEmpty ? 0 : Double(Int8(bitPattern: b[0]))
        case "si16":
            guard b.count >= 2 else { throw SMCError.unsupportedType(v.type) }
            return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1])))
        case "sp78":
            guard b.count >= 2 else { throw SMCError.unsupportedType(v.type) }
            return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256.0
        case "fpe2":
            guard b.count >= 2 else { throw SMCError.unsupportedType(v.type) }
            return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4.0
        case "fp88":
            guard b.count >= 2 else { throw SMCError.unsupportedType(v.type) }
            return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 256.0
        case "ioft":
            // 64-bit fixed point, little-endian, 16 fractional bits. Verified
            // against a co-located key: TG0B decodes to 36.600 while TB0T (flt)
            // reads 36.60 at the same instant.
            guard b.count >= 8 else { throw SMCError.unsupportedType(v.type) }
            var raw: UInt64 = 0
            for byte in b.prefix(8).reversed() { raw = raw << 8 | UInt64(byte) }
            return Double(raw) / 65536.0
        case "si32":
            // Little-endian signed 32-bit. On this hardware these carry indices
            // and counts (observed 1, 1, 7), not temperatures.
            guard b.count >= 4 else { throw SMCError.unsupportedType(v.type) }
            let u = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
            return Double(Int32(bitPattern: u))
        default:
            throw SMCError.unsupportedType(v.type)
        }
    }

    /// Encode a Double back into the byte layout the key expects.
    public static func encode(_ value: Double, type: String, size: UInt32) throws -> [UInt8] {
        switch type {
        case "flt ":
            let bits = Float(value).bitPattern
            return [UInt8(truncatingIfNeeded: bits), UInt8(truncatingIfNeeded: bits >> 8),
                    UInt8(truncatingIfNeeded: bits >> 16), UInt8(truncatingIfNeeded: bits >> 24)]
        case "ui8 ", "flag":
            return [UInt8(clamping: Int(value))]
        case "ui16":
            let v = UInt16(clamping: Int(value))
            return [UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
        case "fpe2":
            let v = UInt16(clamping: Int(value * 4))
            return [UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
        case "sp78":
            let v = Int16(clamping: Int(value * 256))
            return [UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
        default:
            throw SMCError.unsupportedType(type)
        }
    }
}
