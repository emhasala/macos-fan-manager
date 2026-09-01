import SwiftUI
import SMCKit

/// The dropdown behind the menu bar item: a glance at the machine, not a
/// second copy of the dashboard.
struct MenuBarView: View {
    @EnvironmentObject private var monitor: FanMonitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(monitor.device.marketingName)
                .font(.subheadline.weight(.semibold))

            if monitor.capability.fanCount == 0 {
                Text(monitor.capability.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(monitor.fans, id: \.index) { fan in
                    HStack {
                        Text(monitor.fans.count > 1 ? "Fan \(fan.index + 1)" : "Fan")
                            .font(.caption)
                        Spacer()
                        if monitor.appControlled.contains(fan.index) {
                            Image(systemName: "hand.raised.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        Text(verbatim: fan.actual.map { "\(Int($0)) RPM" } ?? "—")
                            .font(.system(.caption, design: .rounded))
                            .monospacedDigit()
                    }
                }
            }

            Divider()

            HStack {
                Text("CPU").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(monitor.thermal.cpu.map { String(format: "%.0f°C", $0) } ?? "—")
                    .font(.system(.caption, design: .rounded)).monospacedDigit()
            }
            HStack {
                Text("Hottest").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(monitor.thermal.hottest.map { String(format: "%.0f°C", $0) } ?? "—")
                    .font(.system(.caption, design: .rounded)).monospacedDigit()
            }

            Divider()

            Button("Open Fan Manager") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Quit") {
                NSApp.terminate(nil)   // AppDelegate restores automatic control
            }
        }
        .buttonStyle(.plain)
        .padding(12)
        .frame(width: 220)
    }
}
