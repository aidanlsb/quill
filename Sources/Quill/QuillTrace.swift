import Darwin
import Foundation
import os

/// `QUILL_TRACE=1` prints millisecond timings and posts os_signpost intervals.
/// The clock starts the first time this type is touched, which `AppDelegate.init` does.
enum QuillTrace {
    static let enabled = ProcessInfo.processInfo.environment["QUILL_TRACE"] == "1"
    private static let log = OSLog(subsystem: "com.aidanlsb.Quill", category: .pointsOfInterest)
    private static let startNanos = DispatchTime.now().uptimeNanoseconds

    static func millisSinceStart() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- startNanos) / 1_000_000
    }

    static func event(_ name: StaticString) {
        guard enabled else { return }
        os_signpost(.event, log: log, name: name)
        write("quill trace \(name) \(format(millisSinceStart()))\n")
    }

    @discardableResult
    static func measure<T>(_ name: StaticString, _ body: () -> T) -> T {
        let began = DispatchTime.now().uptimeNanoseconds
        if enabled {
            os_signpost(.begin, log: log, name: name)
        }
        let value = body()
        if enabled {
            os_signpost(.end, log: log, name: name)
            let ms = Double(DispatchTime.now().uptimeNanoseconds &- began) / 1_000_000
            write("quill trace \(name) \(format(ms))\n")
        }
        return value
    }

    static func format(_ ms: Double) -> String {
        String(format: "%.2f", ms)
    }

    static func write(_ line: String) {
        var bytes = Array(line.utf8)
        bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = Darwin.write(STDERR_FILENO, base, buffer.count)
        }
    }
}
