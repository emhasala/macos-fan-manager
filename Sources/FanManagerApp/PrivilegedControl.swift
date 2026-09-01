import Foundation

/// The app's side of the privilege boundary.
///
/// Writing to the SMC requires root and macOS offers no way around that. This
/// app deliberately does **not** escalate its own privileges: it never prompts
/// for a password, never runs an installer, and never modifies itself. It only
/// reports whether the helper has been enabled and, if not, shows the user the
/// exact command to run.
///
/// That is a deliberate trade of one-time convenience for auditability. Anyone
/// downloading a fan control binary off the internet should be able to see
/// precisely what gains root and when, and nothing here happens behind their
/// back. Monitoring needs none of this and works untouched out of the box.
enum PrivilegedControl {
    enum ControlError: Error, CustomStringConvertible {
        case helperMissing
        case notEnabled
        case helperFailed(String)

        var description: String {
            switch self {
            case .helperMissing:
                return "fan-helper is missing from the app bundle"
            case .notEnabled:
                return "fan control has not been enabled on this Mac yet"
            case .helperFailed(let message):
                return message
            }
        }
    }

    /// Ships next to the app binary in Contents/MacOS.
    static var helperURL: URL? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/fan-helper")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }

        // Running straight out of `swift build` during development.
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("fan-helper")
        return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
    }

    /// True once the helper has been given the privileges it needs.
    static var isEnabled: Bool {
        guard let url = helperURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let owner = attrs[.ownerAccountID] as? NSNumber,
              let perms = attrs[.posixPermissions] as? NSNumber
        else { return false }
        return owner.uint32Value == 0 && (perms.uint16Value & 0o4000) != 0
    }

    /// The one command a user runs to enable control, shown verbatim in the UI
    /// so it can be read before it is trusted.
    /// A path for the copy-and-paste command: no username in it, and correct
    /// when pasted into a shell.
    ///
    /// `abbreviatingWithTildeInPath` is a trap here. The bundle name contains a
    /// space so the path has to be quoted, and a tilde inside quotes is never
    /// expanded -- the command fails with "No such file or directory". `$HOME`
    /// does expand inside double quotes, so it hides the username *and* works.
    private static var displayPath: String? {
        guard let path = helperURL?.path else { return nil }
        let home = NSHomeDirectory()
        guard path.hasPrefix(home + "/") else { return path }
        return "$HOME" + path.dropFirst(home.count)
    }

    static var enableCommand: String {
        guard let path = displayPath else { return "" }
        return "sudo chown root:wheel \"\(path)\" && sudo chmod u+s \"\(path)\""
    }

    static var disableCommand: String {
        guard let path = displayPath else { return "" }
        return "sudo chmod u-s \"\(path)\""
    }

    /// Fans this app has forced, so it can tell its own overrides apart from
    /// the firmware's mode bit.
    ///
    /// macOS drives fans on Apple Silicon by setting `F0Md = 1` itself, so the
    /// mode bit says only "somebody is steering this fan", never who. Inferring
    /// a user override from it reports the OS's own cooling as manual control.
    private(set) static var appForcedFans: Set<Int> = [] {
        didSet { persist() }
    }

    /// Records overrides on disk so a run that dies without cleaning up can be
    /// undone by the next one.
    ///
    /// `applicationWillTerminate` covers a normal quit and nothing else -- not a
    /// crash, not Force Quit, not SIGKILL. A fan pinned low by a run that never
    /// got to tidy up is the failure this guards against.
    private static var stateURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FanManager", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("forced-fans.json")
    }

    private static func persist() {
        if appForcedFans.isEmpty {
            try? FileManager.default.removeItem(at: stateURL)
        } else if let data = try? JSONEncoder().encode(appForcedFans.sorted()) {
            try? data.write(to: stateURL)
        }
    }

    /// Hands back any fan a previous run left forced. Returns what it released.
    static func recoverAbandonedOverrides() -> [Int] {
        guard isEnabled,
              let data = try? Data(contentsOf: stateURL),
              let indices = try? JSONDecoder().decode([Int].self, from: data),
              !indices.isEmpty
        else { return [] }

        var released: [Int] = []
        for index in indices {
            if (try? run(["auto", "\(index)"])) != nil { released.append(index) }
        }
        try? FileManager.default.removeItem(at: stateURL)
        return released
    }

    /// Opens Terminal on a script that runs the setup command.
    ///
    /// The script echoes what it is about to do before doing it, and `sudo`
    /// prompts for the password, so nothing happens that the user cannot see
    /// and refuse. The app still never escalates anything itself.
    static func openSetupInTerminal() throws {
        guard !enableCommand.isEmpty else { throw ControlError.helperMissing }

        // The command contains double quotes, so echoing it inside double
        // quotes nests them; single quotes show it exactly as written instead.
        let quoted = "'" + enableCommand.replacingOccurrences(of: "'", with: "'\\''") + "'"

        let script = """
        #!/bin/bash
        # Fan Manager -- enable fan control
        #
        # Marks the bundled fan-helper setuid root so it can write fan speeds.
        # Undo at any time with:
        #   \(disableCommand)

        echo "Fan Manager needs one-time permission to control fans."
        echo
        echo "About to run:"
        echo "  " \(quoted)
        echo
        if \(enableCommand); then
            echo
            echo "Done. Go back to Fan Manager and click Recheck."
        else
            echo
            echo "Setup failed. Fan Manager will keep working for monitoring."
            exit 1
        fi
        echo "You can close this window."

        """

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fan-manager-setup.command")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )

        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", "Terminal", url.path]
        try open.run()
    }

    @discardableResult
    private static func run(_ arguments: [String]) throws -> String {
        guard let url = helperURL else { throw ControlError.helperMissing }
        guard isEnabled else { throw ControlError.notEnabled }

        let task = Process()
        task.executableURL = url
        task.arguments = arguments
        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err
        try task.run()
        task.waitUntilExit()

        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard task.terminationStatus == 0 else {
            let message = String(
                decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
            )
            throw ControlError.helperFailed(
                message.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func setFan(_ index: Int, rpm: Double) throws {
        try run(["set", "\(index)", "\(Int(rpm))"])
        appForcedFans.insert(index)
    }

    static func setAuto(_ index: Int) throws {
        try run(["auto", "\(index)"])
        appForcedFans.remove(index)
    }

    /// Releases only the fans this app took over.
    ///
    /// Blanket-resetting every fan on quit would clear a mode bit macOS set for
    /// its own reasons, so an app that never forced anything leaves the SMC
    /// exactly as it found it. Best effort -- a thrown error helps nobody here.
    static func restoreAll() {
        for index in appForcedFans {
            _ = try? run(["auto", "\(index)"])
        }
        appForcedFans.removeAll()
    }
}
