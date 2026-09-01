import SwiftUI
import AppKit
import SMCKit

/// Renders the real views to PNG for the README.
///
/// `screencapture` needs Screen Recording permission, which a build script has
/// no business asking for. `ImageRenderer` rasterises the same SwiftUI views
/// with no permissions at all, so the images in the docs come from the actual
/// UI rather than being mocked up separately.
///
/// Live SMC data is used wherever the rendering Mac can provide it. The states
/// this Mac cannot be -- fanless, several fans -- are rendered from fixed
/// values through the same views, and labelled as such in the README.
///
///     Fan\ Manager.app/Contents/MacOS/FanManager --render-screenshots docs/
enum Screenshot {
    /// `--preview <state>` launches the real window driven by fixed data.
    ///
    /// `ImageRenderer` cannot rasterise AppKit-backed controls -- an
    /// `NSSlider` or a segmented `Picker` comes out as a yellow placeholder --
    /// so the dashboard shots are screen-captured from a real window instead,
    /// and this is how that window is put into a state this Mac is not in.
    @MainActor
    static var requestedPreview: FanMonitor? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--preview"), i + 1 < args.count else { return nil }
        switch args[i + 1] {
        case "manual":   return .manualOverride
        case "fanless":  return .fanlessAir
        case "multifan": return .multiFanDesktop
        case "setup":    return .awaitingSetup
        default:         return nil
        }
    }

    static var requestedDirectory: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--render-screenshots"), i + 1 < args.count
        else { return nil }
        return args[i + 1]
    }

    @MainActor
    static func renderAll(into directory: String) async {
        let live = FanMonitor()

        // Sensor discovery walks ~1600 keys and the first poll follows it, so
        // give the monitor time to fill in before rendering an empty dashboard.
        for _ in 0..<40 where !live.isReady {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try? await Task.sleep(nanoseconds: 600_000_000)

        let dir = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Only the menu bar panel: it is pure SwiftUI, so it rasterises
        // cleanly. Everything with a slider or a segmented picker in it is
        // captured from a real window by Scripts/capture-screenshots.sh.
        render(MenuBarView().environmentObject(live), to: dir, "menubar", .light)

        exit(0)
    }

    @MainActor
    private static func dashboard(_ monitor: FanMonitor) -> some View {
        DashboardContent()
            .environmentObject(monitor)
            .frame(width: 520)
    }

    @MainActor
    private static func render(
        _ view: some View, to dir: URL, _ name: String, _ scheme: ColorScheme
    ) {
        // NSColor resolves dynamic colours against the *app's* appearance, not
        // the SwiftUI environment, so both have to be set or a dark render comes
        // back with a light window background.
        NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)

        let renderer = ImageRenderer(
            content: view
                .environment(\.colorScheme, scheme)
                .background(Color(nsColor: .windowBackgroundColor))
        )
        renderer.scale = 2   // Retina, so the README image stays sharp

        let url = dir.appendingPathComponent("\(name).png")
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write(Data("could not render \(name)\n".utf8))
            return
        }
        try? png.write(to: url)
        print("wrote \(url.lastPathComponent)")
    }
}

// MARK: - Fixed states for the docs

@MainActor
extension FanMonitor {
    /// This project's own Mac, with an override applied.
    static let manualOverride = FanMonitor(
        preview: MacDevice(
            modelIdentifier: "Mac14,7",
            marketingName: "MacBook Pro (13-inch, M2, 2022)",
            chip: "Apple M2", isAppleSilicon: true,
            coreCount: 8, memoryBytes: 8 << 30
        ),
        capability: .controllable(fanCount: 1),
        fans: [Fan(index: 0, actual: 4183, min: 1199, max: 7199,
                   target: 4200, forced: true)],
        thermal: ThermalSnapshot(cpu: 61, gpu: 55, battery: 32,
                                 hottest: 74, hottestKey: "TCMz"),
        controlAvailable: true,
        appControlled: [0]
    )

    /// Every M-series MacBook Air: monitoring works, there is nothing to control.
    static let fanlessAir = FanMonitor(
        preview: MacDevice(
            modelIdentifier: "Mac14,2",
            marketingName: "MacBook Air (13-inch, M2, 2022)",
            chip: "Apple M2", isAppleSilicon: true,
            coreCount: 8, memoryBytes: 16 << 30
        ),
        capability: .fanless,
        fans: [],
        thermal: ThermalSnapshot(cpu: 47, gpu: 41, battery: 30,
                                 hottest: 58, hottestKey: "TCMz")
    )

    /// What a first launch looks like before control is enabled.
    static let awaitingSetup = FanMonitor(
        preview: MacDevice(
            modelIdentifier: "Mac14,7",
            marketingName: "MacBook Pro (13-inch, M2, 2022)",
            chip: "Apple M2", isAppleSilicon: true,
            coreCount: 8, memoryBytes: 8 << 30
        ),
        capability: .controllable(fanCount: 1),
        fans: [Fan(index: 0, actual: 2103, min: 1199, max: 7199,
                   target: 2100, forced: false)],
        thermal: ThermalSnapshot(cpu: 52, gpu: 46, battery: 31,
                                 hottest: 64, hottestKey: "TCMz"),
        controlAvailable: false
    )

    /// A desktop with several fans, each with its own range.
    static let multiFanDesktop = FanMonitor(
        preview: MacDevice(
            modelIdentifier: "MacPro7,1",
            marketingName: "Mac Pro (2019)",
            chip: "Intel Xeon W", isAppleSilicon: false,
            coreCount: 28, memoryBytes: 96 << 30
        ),
        capability: .controllable(fanCount: 3),
        fans: [
            Fan(index: 0, actual: 1180, min: 620, max: 2900, target: 1180, forced: false),
            Fan(index: 1, actual: 1904, min: 700, max: 3800, target: 1900, forced: false),
            Fan(index: 2, actual: 840, min: 500, max: 2200, target: 840, forced: false),
        ],
        thermal: ThermalSnapshot(cpu: 58, gpu: 52, battery: nil,
                                 hottest: 71, hottestKey: "TC0P"),
        controlAvailable: true
    )
}
