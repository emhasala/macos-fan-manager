import Foundation
import SMCKit

// fan-helper -- the only part of this project that runs as root.
//
// Installed setuid root, so it is a privilege boundary and is written like one:
// it accepts three fixed verbs, parses nothing but integers and doubles, never
// touches the environment, never spawns anything, and clamps every RPM to the
// range the firmware itself reports. The worst a caller can do is set a legal
// fan speed -- which is the entire point of it existing.

setvbuf(stdout, nil, _IOLBF, 0)

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("fan-helper: " + message + "\n").utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let verb = args.first else {
    die("usage: fan-helper <set <fan> <rpm> | auto <fan> | auto-all | probe>")
}

guard geteuid() == 0 else {
    die("not running as root -- is the setuid bit set on this binary?")
}

let smc: SMC
do { smc = try SMC() } catch { die("\(error)") }

/// Rejects anything that is not a real fan index on this machine.
func validatedFanIndex(_ raw: String) -> Int {
    guard let index = Int(raw) else { die("fan index '\(raw)' is not a number") }
    let count = (try? smc.fanCount()) ?? 0
    guard index >= 0, index < count else {
        die("fan index \(index) out of range (this Mac has \(count))")
    }
    return index
}

switch verb {
case "probe":
    // Lets the app confirm the helper is installed and functional without
    // changing anything.
    print("ok \(( try? smc.fanCount()) ?? 0)")

case "set":
    guard args.count >= 3 else { die("usage: fan-helper set <fan> <rpm>") }
    let index = validatedFanIndex(args[1])
    guard let rpm = Double(args[2]), rpm.isFinite else {
        die("rpm '\(args[2])' is not a number")
    }
    do {
        // setFanTarget re-reads the firmware min/max and refuses anything
        // outside it, so the bounds check lives at the boundary, not here.
        try smc.setFanTarget(index, rpm: rpm)
        try smc.setFanMode(index, forced: true)
        print("ok")
    } catch { die("\(error)") }

case "auto":
    guard args.count >= 2 else { die("usage: fan-helper auto <fan>") }
    let index = validatedFanIndex(args[1])
    do {
        try smc.setFanMode(index, forced: false)
        print("ok")
    } catch { die("\(error)") }

case "auto-all":
    smc.restoreAllFansToAuto()
    print("ok")

default:
    die("unknown verb '\(verb)'")
}
