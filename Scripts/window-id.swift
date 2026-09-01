// Prints the CoreGraphics window number of Fan Manager's main window.
//
// screencapture -l<id> grabs exactly that window even when something overlaps
// it, which a region capture cannot promise. Window *geometry* is readable
// without Screen Recording permission; only the capture itself needs it.

import CoreGraphics
import Foundation

let windows = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
) as? [[String: Any]] ?? []

for window in windows {
    guard let owner = window[kCGWindowOwnerName as String] as? String,
          owner.contains("FanManager") || owner.contains("Fan Manager"),
          let number = window[kCGWindowNumber as String] as? Int,
          let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? Double, width > 300
    else { continue }
    print(number)
    exit(0)
}
FileHandle.standardError.write(Data("no Fan Manager window on screen\n".utf8))
exit(1)
