import SwiftUI
import SMCKit

// MARK: - Shared look

enum Style {
    static let cardRadius: CGFloat = 12
    static let gutter: CGFloat = 16

    /// Cool to hot as a fan approaches its ceiling. Kept in one place so the
    /// gauge, the RPM readout and the menu bar all agree on what "hot" looks like.
    static func heat(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.30: return .cyan
        case ..<0.60: return .green
        case ..<0.80: return .orange
        default: return .red
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(Style.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: Style.cardRadius))
    }
}

// MARK: - Dashboard

struct DashboardView: View {
    @EnvironmentObject private var monitor: FanMonitor

    var body: some View {
        ScrollView { DashboardContent() }
            .background(.background)
    }
}

/// The dashboard minus its scroll view, so `Screenshot` can rasterise it --
/// `ImageRenderer` has no viewport and lays a `ScrollView` out as empty.
struct DashboardContent: View {
    @EnvironmentObject private var monitor: FanMonitor

    var body: some View {
        Group {
            VStack(spacing: Style.gutter) {
                DeviceHeader()

                if let failure = monitor.failure {
                    FailureCard(message: failure)
                } else if !monitor.isReady {
                    ProgressView("Reading sensors…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else {
                    if !monitor.recoveredFans.isEmpty {
                        RecoveredCard(fans: monitor.recoveredFans)
                    }

                    ThermalCard()

                    switch monitor.capability {
                    case .fanless:
                        FanlessCard()
                    case .monitorOnly, .controllable:
                        if monitor.capability.canControl && !monitor.controlAvailable {
                            EnableControlCard()
                        }
                        ForEach(monitor.fans, id: \.index) { fan in
                            FanCard(fan: fan)
                        }
                    }
                }
            }
            .padding(Style.gutter)
        }
        .background(.background)
    }
}

// MARK: - Header

struct DeviceHeader: View {
    @EnvironmentObject private var monitor: FanMonitor

    /// Not every Mac symbol exists on every macOS version, and a missing one
    /// draws as nothing at all rather than failing loudly.
    private var symbol: String {
        let name = monitor.device.symbolName
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
            ? name : "desktopcomputer"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(monitor.device.marketingName)
                    .font(.headline)
                Text("\(monitor.device.chip) · \(monitor.device.coreCount) cores · "
                     + "\(monitor.device.memoryBytes / 1_073_741_824) GB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(monitor.capability.summary)
                    .font(.caption)
                    .foregroundStyle(monitor.capability.canControl ? .green : .secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Temperatures

struct ThermalCard: View {
    @EnvironmentObject private var monitor: FanMonitor

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Temperature").font(.subheadline.weight(.semibold))
                HStack(spacing: 0) {
                    Stat(label: "CPU", value: monitor.thermal.cpu)
                    Stat(label: "GPU", value: monitor.thermal.gpu)
                    Stat(label: "Battery", value: monitor.thermal.battery)
                    Stat(label: monitor.thermal.hottestKey ?? "Hottest",
                         value: monitor.thermal.hottest)
                }
            }
        }
    }

    struct Stat: View {
        let label: String
        let value: Double?

        var body: some View {
            VStack(spacing: 2) {
                Text(value.map { String(format: "%.0f°", $0) } ?? "—")
                    .font(.system(.title3, design: .rounded).weight(.medium))
                    .monospacedDigit()
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Fan card

struct FanCard: View {
    let fan: Fan
    @EnvironmentObject private var monitor: FanMonitor

    @State private var sliderRPM: Double = 0
    @State private var isDragging = false

    /// Read from the monitor, not held here: this view is rebuilt whenever the
    /// monitor publishes, and writing `@State` after that is what crashed.
    private var error: String? { monitor.controlErrors[fan.index] }

    private var minRPM: Double { fan.min ?? 0 }
    private var maxRPM: Double { fan.max ?? 1 }
    /// True only when *this app* is steering the fan. macOS sets the firmware's
    /// mode bit for its own cooling, so `fan.forced` cannot answer this.
    private var isForced: Bool { monitor.appControlled.contains(fan.index) }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: Style.gutter) {
                    FanGauge(fan: fan)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(monitor.fans.count > 1 ? "Fan \(fan.index + 1)" : "Fan")
                            .font(.subheadline.weight(.semibold))
                        Text(isForced ? "Manual" : "Automatic")
                            .font(.caption)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(isForced ? Color.orange.opacity(0.2)
                                                 : Color.secondary.opacity(0.15),
                                        in: Capsule())
                        Text(verbatim: "\(Int(minRPM)) – \(Int(maxRPM)) RPM")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }

                if monitor.capability.canControl && monitor.controlAvailable {
                    controls
                }

                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .onAppear { sliderRPM = max(minRPM, fan.target ?? minRPM) }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { isForced },
                set: { forced in forced ? apply(sliderRPM) : setAuto() }
            )) {
                Text("Automatic").tag(false)
                Text("Manual").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)

            if isForced {
                HStack(spacing: 10) {
                    // Applying on every slider tick would hammer the SMC, so the
                    // write happens when the drag ends.
                    Slider(value: $sliderRPM, in: minRPM...maxRPM, step: 50) { editing in
                        isDragging = editing
                        if !editing { apply(sliderRPM) }
                    }
                    Text(verbatim: "\(Int(sliderRPM))")
                        .font(.system(.callout, design: .rounded))
                        .monospacedDigit()
                        .frame(width: 46, alignment: .trailing)
                        .foregroundStyle(isDragging ? .primary : .secondary)
                }
            }
        }
    }

    // Both deferred into a Task: these run inside AppKit's mouse-tracking
    // callback, and publishing from there rebuilds this view mid-call.
    private func apply(_ rpm: Double) {
        Task { await monitor.force(fan.index, rpm: rpm) }
    }

    private func setAuto() {
        Task { await monitor.releaseToAuto(fan.index) }
    }
}

// MARK: - Gauge

struct FanGauge: View {
    let fan: Fan

    private var fraction: Double {
        guard let actual = fan.actual, let lo = fan.min, let hi = fan.max, hi > lo
        else { return 0 }
        return ((actual - lo) / (hi - lo)).clamped(to: 0...1)
    }

    var body: some View {
        ZStack {
            // 270° sweep, opening at the bottom.
            Arc().stroke(.quaternary, style: .init(lineWidth: 8, lineCap: .round))
            Arc(fraction: fraction)
                .stroke(Style.heat(fraction), style: .init(lineWidth: 8, lineCap: .round))
                .animation(.easeOut(duration: 0.5), value: fraction)

            VStack(spacing: 0) {
                Text(fan.actual.map { String(format: "%.0f", $0) } ?? "—")
                    .font(.system(size: 22, design: .rounded).weight(.medium))
                    .monospacedDigit()
                Text("RPM").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 92, height: 92)
    }

    struct Arc: Shape {
        var fraction: Double = 1

        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.addArc(
                center: CGPoint(x: rect.midX, y: rect.midY),
                radius: rect.width / 2 - 4,
                startAngle: .degrees(135),
                endAngle: .degrees(135 + 270 * fraction),
                clockwise: false
            )
            return path
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - States

struct FanlessCard: View {
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Label("No fans on this Mac", systemImage: "wind")
                    .font(.subheadline.weight(.semibold))
                Text("This model is passively cooled, so there is nothing to control. "
                     + "Temperature monitoring above still works.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Shown when this launch cleaned up after a run that died holding a fan.
struct RecoveredCard: View {
    let fans: [Int]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Label("Recovered a fan left forced", systemImage: "arrow.uturn.backward")
                    .font(.subheadline.weight(.semibold))
                Text("A previous run quit without releasing "
                     + (fans.count == 1 ? "fan \(fans[0] + 1)" : "\(fans.count) fans")
                     + ". Automatic control has been restored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct FailureCard: View {
    let message: String

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Label("Could not reach the SMC", systemImage: "exclamationmark.triangle")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Shown when the hardware supports control but the helper has not been given
/// the privileges it needs. The command is displayed rather than run, so the
/// user can read it before trusting it.
struct EnableControlCard: View {
    @EnvironmentObject private var monitor: FanMonitor
    @State private var copied = false
    @State private var launchError: String?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Fan control needs one-time setup", systemImage: "lock")
                    .font(.subheadline.weight(.semibold))

                Text("Changing fan speed requires root. Run this in Terminal, then "
                     + "click Recheck. Monitoring works without it. Updating the app "
                     + "replaces this file, so a new version needs it again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(PrivilegedControl.enableCommand)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 6))

                HStack {
                    Button("Open in Terminal") {
                        do {
                            try PrivilegedControl.openSetupInTerminal()
                            launchError = nil
                        } catch {
                            launchError = "\(error)"
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Button(copied ? "Copied" : "Copy command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            PrivilegedControl.enableCommand, forType: .string
                        )
                        copied = true
                    }
                    Button("Recheck") {
                        Task { await monitor.recheckControl() }
                    }
                    Spacer()
                }

                if let launchError {
                    Text(launchError).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }
}
