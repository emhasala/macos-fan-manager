import SwiftUI
import AppKit

@main
struct FanManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var monitor = Screenshot.requestedPreview ?? FanMonitor()

    var body: some Scene {
        Window("Fan Manager", id: "main") {
            DashboardView()
                .environmentObject(monitor)
                .frame(minWidth: 460, idealWidth: 520, minHeight: 420)
        }
        .windowResizability(.contentMinSize)
        .commands { CommandGroup(replacing: .newItem) {} }

        MenuBarExtra {
            MenuBarView().environmentObject(monitor)
        } label: {
            // Text rather than an icon-only label: the whole point of a menu bar
            // item here is reading the RPM without opening anything.
            HStack(spacing: 3) {
                Image(systemName: "fan")
                Text(monitor.menuBarLabel)
            }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Documentation capture: pin the appearance so light and dark shots are
        // reproducible regardless of the system setting.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--appearance"), i + 1 < args.count {
            NSApp.appearance = NSAppearance(named: args[i + 1] == "dark" ? .darkAqua : .aqua)

            // A capture wants a known window size, not whatever the user last
            // dragged it to and AppKit restored. Stated explicitly per state:
            // the dashboard is a ScrollView, whose fittingSize says nothing
            // about how tall its content actually is.
            var size = NSSize(width: 540, height: 620)
            if let j = args.firstIndex(of: "--window-size"), j + 1 < args.count {
                let parts = args[j + 1].split(separator: "x").compactMap { Double($0) }
                if parts.count == 2 { size = NSSize(width: parts[0], height: parts[1]) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return }
                window.setContentSize(size)
                window.center()
            }
        }

        // Documentation build: render the views and quit without ever showing UI.
        if let directory = Screenshot.requestedDirectory {
            NSApp.setActivationPolicy(.prohibited)
            Task { @MainActor in await Screenshot.renderAll(into: directory) }
        }
    }

    /// A fan left in forced mode stays forced after the app is gone, so quitting
    /// hands every fan back to macOS. This is the last line of defence against
    /// leaving a machine with its cooling pinned.
    func applicationWillTerminate(_ notification: Notification) {
        PrivilegedControl.restoreAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false   // menu bar item keeps running
    }
}
