import Foundation
import IOKit

// MARK: - Machine identification

public struct MacDevice: Sendable {
    public let modelIdentifier: String   // "Mac14,7"
    public let marketingName: String     // "MacBook Pro (13-inch, M2, 2022)"
    public let chip: String              // "Apple M2"
    public let isAppleSilicon: Bool
    public let coreCount: Int
    public let memoryBytes: UInt64

    public static let current = MacDevice()

    /// SF Symbol matching the machine, so a Mac Pro is not drawn as a laptop.
    ///
    /// Keyed off the marketing name rather than the model identifier: Apple
    /// Silicon identifiers ("Mac14,7") say nothing about the form factor.
    public var symbolName: String {
        let name = marketingName
        if name.contains("MacBook") { return "laptopcomputer" }
        if name.contains("Mac mini") { return "macmini" }
        if name.contains("Mac Studio") { return "macstudio" }
        if name.contains("Mac Pro") { return "macpro.gen3" }
        if name.contains("iMac") { return "desktopcomputer" }
        return modelIdentifier.hasPrefix("MacBook") ? "laptopcomputer" : "desktopcomputer"
    }

    /// Fixed values, for documenting how the UI looks on Macs other than the
    /// one doing the rendering.
    public init(modelIdentifier: String, marketingName: String, chip: String,
                isAppleSilicon: Bool, coreCount: Int, memoryBytes: UInt64) {
        self.modelIdentifier = modelIdentifier
        self.marketingName = marketingName
        self.chip = chip
        self.isAppleSilicon = isAppleSilicon
        self.coreCount = coreCount
        self.memoryBytes = memoryBytes
    }

    private init() {
        modelIdentifier = MacDevice.sysctlString("hw.model") ?? "unknown"
        chip = MacDevice.sysctlString("machdep.cpu.brand_string") ?? "unknown"
        coreCount = Int(MacDevice.sysctlInt("hw.ncpu") ?? 0)
        memoryBytes = MacDevice.sysctlInt("hw.memsize") ?? 0
        #if arch(arm64)
        isAppleSilicon = true
        #else
        isAppleSilicon = false
        #endif
        marketingName = MacDevice.productName()
            ?? MacDevice.inferredFamily(from: modelIdentifier)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func sysctlInt(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    /// The device tree carries the full marketing string ("MacBook Pro
    /// (13-inch, M2, 2022)") on Apple Silicon. Intel Macs generally lack this
    /// node, hence the family fallback.
    private static func productName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }

        guard let cf = IORegistryEntryCreateCFProperty(
            entry, "product-name" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? Data else { return nil }

        // Stored as a NUL-terminated C string inside the data blob.
        let name = String(decoding: cf.prefix(while: { $0 != 0 }), as: UTF8.self)
        return name.isEmpty ? nil : name
    }

    /// Best-effort family name from the model identifier, for Macs without a
    /// product-name node. Intel identifiers are self-describing ("MacBookPro18,3");
    /// Apple Silicon ones ("Mac14,7") are not, so those just pass through.
    private static func inferredFamily(from identifier: String) -> String {
        let families = [
            ("MacBookPro", "MacBook Pro"), ("MacBookAir", "MacBook Air"),
            ("MacBook", "MacBook"), ("Macmini", "Mac mini"),
            ("MacPro", "Mac Pro"), ("iMacPro", "iMac Pro"),
            ("iMac", "iMac"), ("MacStudio", "Mac Studio"),
        ]
        for (prefix, name) in families where identifier.hasPrefix(prefix) {
            return name
        }
        return identifier
    }
}

// MARK: - What this machine can actually do

public enum FanCapability: Equatable, Sendable {
    /// No fans at all -- every M-series MacBook Air, and the fanless mini/iMac
    /// variants. Monitoring still works; there is simply nothing to control.
    case fanless
    /// Fans report RPM but the firmware will not accept writes to them.
    case monitorOnly(fanCount: Int)
    /// Fans present and the firmware marks the control keys writable.
    case controllable(fanCount: Int)

    public var fanCount: Int {
        switch self {
        case .fanless: return 0
        case .monitorOnly(let n), .controllable(let n): return n
        }
    }

    public var canControl: Bool {
        if case .controllable = self { return true }
        return false
    }

    public var summary: String {
        switch self {
        case .fanless:
            return "No fans \u{2014} this Mac is passively cooled"
        case .monitorOnly(let n):
            return "\(n) fan\(n == 1 ? "" : "s") \u{2014} monitoring only, firmware blocks control"
        case .controllable(let n):
            return "\(n) fan\(n == 1 ? "" : "s") \u{2014} monitoring and control available"
        }
    }
}

extension SMC {
    /// Probes what this specific Mac supports. Treats a missing or zero `FNum`
    /// as fanless rather than an error, since that is the expected state on
    /// passively cooled machines rather than a failure.
    public func capability() -> FanCapability {
        guard let count = try? fanCount(), count > 0 else { return .fanless }

        // The firmware advertises writability per key; trust that over a
        // hardcoded model list, which would go stale with every new Mac.
        let modeWritable = (try? read("F0Md").isWritable) ?? false
        let targetWritable = (try? read("F0Tg").isWritable) ?? false

        return modeWritable && targetWritable
            ? .controllable(fanCount: count)
            : .monitorOnly(fanCount: count)
    }
}
