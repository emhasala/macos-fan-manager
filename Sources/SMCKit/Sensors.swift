import Foundation

// MARK: - Temperature sensors
//
// Sensor naming is not portable across Macs, so nothing here hardcodes a key.
// The prefixes are stable families -- Tp* CPU cores, Tg* GPU, TB* battery --
// and everything is discovered at runtime and averaged, which keeps working on
// Macs this was never run on.

public struct ThermalSnapshot: Sendable {
    public let cpu: Double?
    public let gpu: Double?
    public let battery: Double?
    public let hottest: Double?
    public let hottestKey: String?

    public init(cpu: Double?, gpu: Double?, battery: Double?,
                hottest: Double?, hottestKey: String?) {
        self.cpu = cpu
        self.gpu = gpu
        self.battery = battery
        self.hottest = hottest
        self.hottestKey = hottestKey
    }

    public static let empty = ThermalSnapshot(
        cpu: nil, gpu: nil, battery: nil, hottest: nil, hottestKey: nil
    )
}

/// The set of readable temperature keys on this Mac, resolved once.
///
/// Discovery walks all ~1600 SMC keys, so it is deliberately separate from
/// polling: build this once, then reuse it for every refresh.
public struct SensorSet: Sendable {
    public let cpu: [String]
    public let gpu: [String]
    public let battery: [String]
    public let all: [String]

    public static let empty = SensorSet(cpu: [], gpu: [], battery: [], all: [])
}

extension SMC {
    /// Walks every SMC key and keeps the temperature sensors that return a
    /// plausible reading. Slow (a second or so) -- call once, off the main thread.
    public func discoverSensors() -> SensorSet {
        guard let keys = try? allKeys() else { return .empty }

        var cpu: [String] = [], gpu: [String] = [], battery: [String] = [], all: [String] = []
        for key in keys where key.hasPrefix("T") {
            // A sensor that reads outside this range is either unpopulated or
            // not actually a temperature, so drop it rather than average it in.
            guard let value = try? read(key).double, value > 0, value < 130 else { continue }
            all.append(key)
            if key.hasPrefix("Tp") { cpu.append(key) }
            else if key.hasPrefix("Tg") { gpu.append(key) }
            else if key.hasPrefix("TB") { battery.append(key) }
        }
        return SensorSet(cpu: cpu, gpu: gpu, battery: battery, all: all)
    }

    public func thermalSnapshot(_ sensors: SensorSet) -> ThermalSnapshot {
        func average(_ keys: [String]) -> Double? {
            let values = keys.compactMap { try? read($0).double }.filter { $0 > 0 && $0 < 130 }
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }

        var hottest: Double?
        var hottestKey: String?
        for key in sensors.all {
            guard let value = try? read(key).double, value > 0, value < 130 else { continue }
            if hottest == nil || value > hottest! {
                hottest = value
                hottestKey = key
            }
        }

        return ThermalSnapshot(
            cpu: average(sensors.cpu),
            gpu: average(sensors.gpu),
            battery: average(sensors.battery),
            hottest: hottest,
            hottestKey: hottestKey
        )
    }
}
