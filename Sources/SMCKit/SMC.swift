import Foundation
import IOKit

// MARK: - Raw AppleSMC structures
//
// These mirror the C layout AppleSMC expects (80 bytes total). Swift lays out
// plain structs in declaration order with natural alignment, which matches --
// `SMC.verifyLayout()` asserts it at startup rather than trusting that silently.

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
    // C gives this struct 3 bytes of trailing padding to reach its 4-byte
    // alignment. Swift is free to pack the *next* field into that padding, so
    // the padding has to be spelled out or the whole struct shrinks to 76.
    var reserved0: UInt8 = 0
    var reserved1: UInt8 = 0
    var reserved2: UInt8 = 0
}

typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private let zeroBytes: SMCBytes = (
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
)

struct SMCKeyData {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = zeroBytes
}

// MARK: - Selectors

private enum Selector {
    static let handleYPCEvent: UInt32 = 2   // the only IOConnectCallStructMethod index
    static let readKey: UInt8 = 5
    static let writeKey: UInt8 = 6
    static let getKeyCount: UInt8 = 7
    static let getKeyFromIndex: UInt8 = 8
    static let getKeyInfo: UInt8 = 9
}

// MARK: - FourCC helpers

/// Packs a 4-character SMC key ("F0Ac") into the big-endian UInt32 the SMC wants.
func fourCC(_ s: String) -> UInt32 {
    var out: UInt32 = 0
    for byte in s.utf8.prefix(4) { out = (out << 8) | UInt32(byte) }
    return out
}

func fourCCString(_ v: UInt32) -> String {
    let chars = [
        UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff),
        UInt8((v >> 8) & 0xff), UInt8(v & 0xff),
    ]
    return String(decoding: chars, as: UTF8.self)
}

// MARK: - Errors

public enum SMCError: Error, CustomStringConvertible {
    case serviceNotFound
    case openFailed(kern_return_t)
    case callFailed(key: String, kern_return_t)
    case smcRejected(key: String, result: UInt8)
    case unknownType(key: String, type: String)
    case notWritable(key: String)
    case outOfRange(rpm: Double, min: Double, max: Double)
    case layoutMismatch(Int)

    public var description: String {
        switch self {
        case .serviceNotFound:
            return "AppleSMC service not found (is this a real Mac, not a VM?)"
        case .openFailed(let kr):
            return "IOServiceOpen failed: 0x\(String(kr, radix: 16))"
        case .callFailed(let key, let kr):
            return "SMC call for \(key) failed: 0x\(String(kr, radix: 16))"
        case .smcRejected(let key, let result):
            // 132 = key not found, the common one worth naming.
            let hint = result == 132 ? " (key not present on this Mac)" : ""
            return "SMC rejected \(key): result=\(result)\(hint)"
        case .unknownType(let key, let type):
            return "\(key) has unhandled data type '\(type)'"
        case .notWritable(let key):
            return "\(key) is not writable"
        case .outOfRange(let rpm, let min, let max):
            return String(format: "%.0f RPM is outside this fan's range (%.0f-%.0f)", rpm, min, max)
        case .layoutMismatch(let size):
            return "SMCKeyData is \(size) bytes, expected 80 -- struct layout is wrong"
        }
    }
}

// MARK: - Key attribute bits
//
// The attribute byte the SMC returns alongside every key. Note that 0x02 is
// *private* write (an internal firmware path), not the flag that says a key
// accepts writes from us -- that one is 0x40.

public enum SMCAttr {
    public static let privateWrite: UInt8 = 0x01
    public static let privateRead:  UInt8 = 0x02
    public static let atomic:       UInt8 = 0x04
    public static let const:        UInt8 = 0x08
    public static let function:     UInt8 = 0x10
    public static let write:        UInt8 = 0x40
    public static let read:         UInt8 = 0x80
}

// MARK: - Decoded value

public struct SMCValue {
    public let key: String
    public let type: String
    public let data: [UInt8]
    public let attributes: UInt8

    public var isReadable: Bool { attributes & SMCAttr.read != 0 }
    public var isWritable: Bool { attributes & SMCAttr.write != 0 }

    public var attributeNames: [String] {
        var names: [String] = []
        if attributes & SMCAttr.read != 0 { names.append("read") }
        if attributes & SMCAttr.write != 0 { names.append("write") }
        if attributes & SMCAttr.function != 0 { names.append("function") }
        if attributes & SMCAttr.const != 0 { names.append("const") }
        if attributes & SMCAttr.atomic != 0 { names.append("atomic") }
        if attributes & SMCAttr.privateRead != 0 { names.append("privRead") }
        if attributes & SMCAttr.privateWrite != 0 { names.append("privWrite") }
        return names
    }

    /// Decodes the SMC's fixed-point and float encodings into a Double.
    public var double: Double? {
        switch type {
        case "flt ":
            guard data.count >= 4 else { return nil }
            // Float32, little-endian, despite keys being big-endian.
            let bits = UInt32(data[0]) | UInt32(data[1]) << 8
                     | UInt32(data[2]) << 16 | UInt32(data[3]) << 24
            return Double(Float(bitPattern: bits))
        case "ui8 ", "ui16", "ui32", "ui64":
            var v: UInt64 = 0
            for b in data { v = (v << 8) | UInt64(b) }   // big-endian
            return Double(v)
        case "si8 ", "si16":
            var v: Int64 = 0
            for b in data { v = (v << 8) | Int64(b) }
            let bits = data.count * 8
            // Sign-extend from the actual width.
            if bits < 64, v & (1 << (bits - 1)) != 0 { v -= (1 << bits) }
            return Double(v)
        case "fpe2":
            guard data.count >= 2 else { return nil }
            return Double((UInt16(data[0]) << 8 | UInt16(data[1])) >> 2)
        case "fp1f": return fixed(fractionBits: 15)
        case "fp4c": return fixed(fractionBits: 12)
        case "fp5b": return fixed(fractionBits: 11)
        case "fp6a": return fixed(fractionBits: 10)
        case "fp79": return fixed(fractionBits: 9)
        case "fp88": return fixed(fractionBits: 8)
        case "fpa6": return fixed(fractionBits: 6)
        case "fpc4": return fixed(fractionBits: 4)
        case "sp78": return signedFixed(fractionBits: 8)
        case "sp87": return signedFixed(fractionBits: 7)
        case "sp96": return signedFixed(fractionBits: 6)
        case "spb4": return signedFixed(fractionBits: 4)
        default:
            return nil
        }
    }

    private func fixed(fractionBits: Int) -> Double? {
        guard data.count >= 2 else { return nil }
        let raw = UInt16(data[0]) << 8 | UInt16(data[1])
        return Double(raw) / Double(1 << fractionBits)
    }

    private func signedFixed(fractionBits: Int) -> Double? {
        guard data.count >= 2 else { return nil }
        let raw = Int16(bitPattern: UInt16(data[0]) << 8 | UInt16(data[1]))
        return Double(raw) / Double(1 << fractionBits)
    }

    public var hex: String { data.map { String(format: "%02x", $0) }.joined(separator: " ") }
}

// MARK: - SMC connection

public final class SMC {
    private var connection: io_connect_t = 0

    public init() throws {
        guard MemoryLayout<SMCKeyData>.stride == 80 else {
            throw SMCError.layoutMismatch(MemoryLayout<SMCKeyData>.stride)
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }

        let kr = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard kr == kIOReturnSuccess else { throw SMCError.openFailed(kr) }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    private func call(_ input: inout SMCKeyData) throws -> SMCKeyData {
        var output = SMCKeyData()
        var outSize = MemoryLayout<SMCKeyData>.stride
        let kr = IOConnectCallStructMethod(
            connection, Selector.handleYPCEvent,
            &input, MemoryLayout<SMCKeyData>.stride,
            &output, &outSize
        )
        guard kr == kIOReturnSuccess else {
            throw SMCError.callFailed(key: fourCCString(input.key), kr)
        }
        guard output.result == 0 else {
            throw SMCError.smcRejected(key: fourCCString(input.key), result: output.result)
        }
        return output
    }

    /// Asks the SMC how big a key's payload is and how it's encoded.
    private func keyInfo(_ key: String) throws -> SMCKeyInfoData {
        var input = SMCKeyData()
        input.key = fourCC(key)
        input.data8 = Selector.getKeyInfo
        return try call(&input).keyInfo
    }

    public func read(_ key: String) throws -> SMCValue {
        let info = try keyInfo(key)

        var input = SMCKeyData()
        input.key = fourCC(key)
        input.keyInfo = info
        input.data8 = Selector.readKey

        let output = try call(&input)
        let size = Int(info.dataSize)
        let bytes = withUnsafeBytes(of: output.bytes) { raw in
            (0..<min(size, 32)).map { raw[$0] }
        }
        return SMCValue(key: key, type: fourCCString(info.dataType), data: bytes,
                        attributes: info.dataAttributes)
    }

    public func write(_ key: String, bytes newBytes: [UInt8]) throws {
        let info = try keyInfo(key)
        guard info.dataAttributes & SMCAttr.write != 0 else { throw SMCError.notWritable(key: key) }

        var input = SMCKeyData()
        input.key = fourCC(key)
        input.keyInfo = info
        input.data8 = Selector.writeKey
        withUnsafeMutableBytes(of: &input.bytes) { raw in
            for (i, b) in newBytes.prefix(min(Int(info.dataSize), 32)).enumerated() {
                raw[i] = b
            }
        }
        _ = try call(&input)
    }

    /// Enumerates every key the SMC knows about -- the discovery tool.
    public func allKeys() throws -> [String] {
        let count = Int(try keyCount())
        var keys: [String] = []
        keys.reserveCapacity(count)
        for i in 0..<count {
            var probe = SMCKeyData()
            probe.data8 = Selector.getKeyFromIndex
            probe.data32 = UInt32(i)
            guard let out = try? call(&probe) else { continue }
            keys.append(fourCCString(out.key))
        }
        return keys
    }

    /// The SMC reports its own key count through an ordinary key rather than
    /// through the getKeyCount selector, which returns nothing useful here.
    public func keyCount() throws -> UInt32 {
        UInt32(try read("#KEY").double ?? 0)
    }
}

// MARK: - Fan model

public struct Fan: Sendable {
    public let index: Int
    public let actual: Double?
    public let min: Double?
    public let max: Double?
    public let target: Double?
    public let forced: Bool?

    public init(index: Int, actual: Double?, min: Double?, max: Double?,
                target: Double?, forced: Bool?) {
        self.index = index
        self.actual = actual
        self.min = min
        self.max = max
        self.target = target
        self.forced = forced
    }
}

extension SMC {
    public func fanCount() throws -> Int {
        Int(try read("FNum").double ?? 0)
    }

    public func fans() throws -> [Fan] {
        let count = try fanCount()
        return (0..<count).map { i in
            Fan(
                index: i,
                actual: try? read("F\(i)Ac").double,
                min:    try? read("F\(i)Mn").double,
                max:    try? read("F\(i)Mx").double,
                target: try? read("F\(i)Tg").double,
                forced: (try? read("F\(i)Md").double).map { $0 != 0 }
            )
        }
    }
}

// MARK: - Fan control (requires root)

extension SMC {
    /// Encodes a Double into the 4-byte little-endian Float32 the fan keys use.
    private static func fltBytes(_ value: Double) -> [UInt8] {
        let bits = Float(value).bitPattern
        return [UInt8(bits & 0xff), UInt8((bits >> 8) & 0xff),
                UInt8((bits >> 16) & 0xff), UInt8((bits >> 24) & 0xff)]
    }

    /// Hands a fan back to macOS's thermal curve, or takes it away from it.
    ///
    /// Leaving a fan forced is the dangerous state: the OS stops managing it, so
    /// a forced-low fan under load will cook the machine. Every caller that sets
    /// this true is responsible for setting it false again.
    public func setFanMode(_ index: Int, forced: Bool) throws {
        try write("F\(index)Md", bytes: [forced ? 1 : 0])
    }

    /// Sets a fan's target RPM, refusing anything outside the firmware's own limits.
    public func setFanTarget(_ index: Int, rpm: Double) throws {
        let lo = try read("F\(index)Mn").double ?? 0
        let hi = try read("F\(index)Mx").double ?? 0
        guard rpm >= lo, rpm <= hi else {
            throw SMCError.outOfRange(rpm: rpm, min: lo, max: hi)
        }
        try write("F\(index)Tg", bytes: SMC.fltBytes(rpm))
    }

    /// Best-effort return of every fan to automatic control. Safe to call twice.
    public func restoreAllFansToAuto() {
        guard let count = try? fanCount() else { return }
        for i in 0..<count { try? setFanMode(i, forced: false) }
    }
}
