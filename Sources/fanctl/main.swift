import Foundation
import SMCKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

func rpm(_ v: Double?) -> String {
    guard let v else { return "  --  " }
    return String(format: "%6.0f", v)
}

func printFans(_ smc: SMC) throws {
    let fans = try smc.fans()
    guard !fans.isEmpty else {
        print("No fans reported (FNum = 0) -- this Mac is passively cooled.")
        return
    }
    print("fan   actual     min     max  target  mode")
    print("---  -------  ------  ------  ------  ------")
    for f in fans {
        let mode = f.forced.map { $0 ? "forced" : "auto" } ?? "?"
        print("  \(f.index)  \(rpm(f.actual))  \(rpm(f.min))  \(rpm(f.max))  \(rpm(f.target))  \(mode)")
    }
}

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "list"

let smc: SMC
do {
    smc = try SMC()
} catch {
    fail("\(error)")
}

switch command {
case "list":
    do { try printFans(smc) } catch { fail("\(error)") }

case "watch":
    // Redraw in place until interrupted.
    signal(SIGINT) { _ in print("\u{1B}[?25h"); exit(0) }
    print("\u{1B}[?25l", terminator: "")   // hide cursor
    while true {
        print("\u{1B}[H\u{1B}[2J", terminator: "")  // home + clear
        print("fanctl watch -- \(Date().formatted(date: .omitted, time: .standard))\n")
        do { try printFans(smc) } catch { print("error: \(error)") }
        fflush(stdout)
        Thread.sleep(forTimeInterval: 1)
    }

case "keys":
    do {
        let keys = try smc.allKeys()
        print("\(keys.count) keys")
        for key in keys.sorted() {
            if let v = try? smc.read(key) {
                let decoded = v.double.map { String(format: "%.3f", $0) } ?? "[\(v.hex)]"
                print(String(format: "%-6s %-6s %@", (key as NSString).utf8String!,
                             (v.type as NSString).utf8String!, decoded))
            }
        }
    } catch { fail("\(error)") }

case "read":
    guard args.count >= 2 else { fail("usage: fanctl read <KEY>") }
    do {
        let v = try smc.read(args[1])
        let decoded = v.double.map { String(format: "%.3f", $0) } ?? "(undecoded)"
        let w = v.isWritable ? "rw" : "ro"
        print("\(v.key)  type=\(v.type)  \(w)  attr=0x\(String(v.attributes, radix: 16))  raw=[\(v.hex)]  value=\(decoded)")
    } catch { fail("\(error)") }

case "temps":
    // Apple Silicon uses Tp**/Tg** sensor names; Intel uses TC0P etc.
    do {
        let keys = try smc.allKeys().filter { $0.hasPrefix("T") }
        for key in keys.sorted() {
            guard let v = try? smc.read(key), let d = v.double, d > 0, d < 130 else { continue }
            print(String(format: "%-6s %6.2f C", (key as NSString).utf8String!, d))
        }
    } catch { fail("\(error)") }

case "set":
    guard args.count >= 2 else { fail("usage: fanctl set <rpm|auto> [fan-index]") }
    guard geteuid() == 0 else { fail("`set` writes to the SMC and must run as root (try sudo)") }
    let fanIndex = args.count >= 3 ? Int(args[2]) ?? 0 : 0

    if args[1] == "auto" {
        do { try smc.setFanMode(fanIndex, forced: false) } catch { fail("\(error)") }
        print("fan \(fanIndex) returned to automatic control")
        break
    }

    guard let wanted = Double(args[1]) else { fail("'\(args[1])' is not an RPM value or 'auto'") }

    // Restoring on the way out is the whole safety story here: a fan left in
    // forced mode stays there after this process dies, including forced *low*.
    // So the process holds the foreground for as long as the override lasts,
    // and every exit path -- clean, Ctrl-C, SIGTERM -- goes through restore.
    var restored = false
    let restore = {
        guard !restored else { return }
        restored = true
        smc.restoreAllFansToAuto()
        print("\nfans returned to automatic control")
    }

    for sig in [SIGINT, SIGTERM] { signal(sig, SIG_IGN) }
    let sources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { restore(); exit(0) }
        src.resume()
        return src
    }
    _ = sources   // keep alive

    do {
        try smc.setFanTarget(fanIndex, rpm: wanted)
        try smc.setFanMode(fanIndex, forced: true)
    } catch {
        restore()
        fail("\(error)")
    }

    print("fan \(fanIndex) forced to \(Int(wanted)) RPM -- press Ctrl-C to release")
    dispatchMain()

case "info":
    let d = MacDevice.current
    let cap = smc.capability()
    print(d.marketingName)
    print("  model     \(d.modelIdentifier)")
    print("  chip      \(d.chip) \(d.isAppleSilicon ? "(Apple Silicon)" : "(Intel)")")
    print("  cores     \(d.coreCount)")
    print("  memory    \(d.memoryBytes / 1_073_741_824) GB")
    print("  cooling   \(cap.summary)")
    if cap.fanCount > 0 {
        print("")
        do { try printFans(smc) } catch { fail("\(error)") }
    }

case "-h", "--help", "help":
    print("""
    fanctl -- inspect and control this Mac's fans

      info          this Mac, and what it supports
      list          fan count and per-fan RPM
      watch         live-updating fan table
      keys          dump every SMC key with decoded value
      read <KEY>    read one key, e.g. `fanctl read F0Ac`
      temps         temperature sensors

    The above are read-only and need no privileges.

      set <rpm> [fan]   force a fan to a fixed RPM (root; holds until Ctrl-C)
      set auto  [fan]   hand the fan back to macOS

    Forcing a fan disables the OS thermal curve for it. `set` stays in the
    foreground and restores automatic control on exit for exactly that reason.
    """)

default:
    fail("unknown command '\(command)' -- try `fanctl help`")
}
