import CoreGraphics
import Foundation

/// Prints onscreen windows, or exits 0 when a pid owns a document-sized one.
/// `--count PID` prints how many document-sized windows that pid owns.
/// Menu-bar strips are short; a Quill window is not.
let arguments = Array(CommandLine.arguments.dropFirst())
let list = arguments.contains("--list")
let wantCount = arguments.contains("--count")
let wanted = arguments.first { $0 != "--list" && $0 != "--count" }.flatMap(Int.init)

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    fputs("onscreen-window: window list unavailable\n", stderr)
    exit(2)
}

func number(_ value: Any?) -> Double {
    (value as? NSNumber)?.doubleValue ?? 0
}

func isDocumentSized(layer: Int, width: Double, height: Double) -> Bool {
    layer == 0 && width > 200 && height > 100
}

var matched = false
var matchCount = 0
for window in windows {
    let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.intValue ?? -1
    let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
    let bounds = window[kCGWindowBounds as String] as? [String: Any]
    let width = number(bounds?["Width"])
    let height = number(bounds?["Height"])
    let name = window[kCGWindowOwnerName as String] as? String ?? ""
    if list {
        print("pid=\(pid) layer=\(layer) \(Int(width))x\(Int(height)) \(name)")
    }
    guard let wanted, pid == wanted else { continue }
    if isDocumentSized(layer: layer, width: width, height: height) {
        matched = true
        matchCount += 1
    }
}

if wantCount {
    if wanted == nil {
        fputs("onscreen-window: --count needs a pid\n", stderr)
        exit(2)
    }
    print(matchCount)
    exit(0)
}

if list, wanted == nil {
    exit(0)
}
exit(matched ? 0 : 1)
