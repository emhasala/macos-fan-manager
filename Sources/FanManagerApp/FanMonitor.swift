import Foundation
import Combine
import SMCKit

/// Everything the UI knows about the machine, refreshed on a timer.
///
/// SMC reads are IOKit round-trips -- a full refresh touches a few dozen keys --
/// so all of it happens on a background queue and only the finished snapshot
/// crosses back to the main actor.
@MainActor
final class FanMonitor: ObservableObject {
    @Published private(set) var device = MacDevice.current
    @Published private(set) var capability: FanCapability = .fanless
    @Published private(set) var fans: [Fan] = []
    @Published private(set) var thermal: ThermalSnapshot = .empty
    @Published private(set) var failure: String?
    @Published private(set) var isReady = false

    /// Whether the privileged helper is installed and usable.
    @Published var controlAvailable = false

    /// Fans this app is currently steering. Kept separate from the firmware's
    /// mode bit, which macOS sets for its own cooling on Apple Silicon.
    @Published private(set) var appControlled: Set<Int> = []

    /// Last control failure per fan. Lives here rather than in `@State` on the
    /// fan card: writing view state after a publish tears down the very view
    /// doing the writing.
    @Published private(set) var controlErrors: [Int: String] = [:]

    /// Fans a previous run left forced and this launch handed back.
    @Published private(set) var recoveredFans: [Int] = []

    private let worker = SMCWorker()
    private var timer: Timer?

    init() {
        Task { await start() }
    }

    /// A monitor with fixed values and no SMC connection.
    ///
    /// Used only to render the documentation screenshots for Macs other than
    /// the one building them -- a fanless Air, a multi-fan desktop -- so the
    /// README can show every state the UI has without owning every Mac.
    init(preview device: MacDevice, capability: FanCapability, fans: [Fan],
         thermal: ThermalSnapshot, controlAvailable: Bool = false,
         appControlled: Set<Int> = []) {
        self.device = device
        self.capability = capability
        self.fans = fans
        self.thermal = thermal
        self.controlAvailable = controlAvailable
        self.appControlled = appControlled
        self.isReady = true
    }

    private func start() async {
        do {
            try await worker.connect()
        } catch {
            failure = "\(error)"
            isReady = true
            return
        }

        capability = await worker.capability()
        controlAvailable = PrivilegedControl.isEnabled

        // A crash or force-quit never runs applicationWillTerminate, so a fan
        // can outlive the app still pinned. Anything a previous run left forced
        // is handed back before this one starts.
        recoveredFans = PrivilegedControl.recoverAbandonedOverrides()

        // Sensor discovery walks all ~1600 keys, so it runs once and the result
        // is reused for every poll after this.
        await worker.discoverSensors()

        await refresh()
        isReady = true

        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        let snapshot = await worker.snapshot()
        fans = snapshot.fans
        thermal = snapshot.thermal
    }

    /// Re-reads capability and helper state after the user grants privileges.
    func recheckControl() async {
        controlAvailable = PrivilegedControl.isEnabled
        capability = await worker.capability()
        await refresh()
    }

    /// Both of these are `async` on purpose.
    ///
    /// They publish, and SwiftUI applies a publish synchronously when it lands
    /// inside an AppKit event callback -- which is where a slider's
    /// `onEditingChanged` runs. Mutating from there rebuilds the calling view
    /// mid-callback and invalidates its `@State`. Awaiting hops to the next
    /// main-actor turn, after AppKit is done with the event.
    func force(_ index: Int, rpm: Double) async {
        do {
            try PrivilegedControl.setFan(index, rpm: rpm)
            appControlled.insert(index)
            controlErrors[index] = nil
        } catch {
            controlErrors[index] = "\(error)"
        }
        await refresh()
    }

    func releaseToAuto(_ index: Int) async {
        do {
            try PrivilegedControl.setAuto(index)
            appControlled.remove(index)
            controlErrors[index] = nil
        } catch {
            controlErrors[index] = "\(error)"
        }
        await refresh()
    }

    var menuBarLabel: String {
        guard let rpm = fans.first?.actual else { return "--" }
        return rpm > 0 ? "\(Int(rpm))" : "idle"
    }
}

struct SMCSnapshot: Sendable {
    let fans: [Fan]
    let thermal: ThermalSnapshot
}

/// Serialises every SMC call onto one background actor. The connection is not
/// thread-safe, so nothing else is allowed to touch it.
actor SMCWorker {
    private var smc: SMC?
    private var sensors: SensorSet = .empty

    func connect() throws {
        smc = try SMC()
    }

    func capability() -> FanCapability {
        smc?.capability() ?? .fanless
    }

    func discoverSensors() {
        sensors = smc?.discoverSensors() ?? .empty
    }

    func snapshot() -> SMCSnapshot {
        guard let smc else { return SMCSnapshot(fans: [], thermal: .empty) }
        return SMCSnapshot(
            fans: (try? smc.fans()) ?? [],
            thermal: smc.thermalSnapshot(sensors)
        )
    }
}
