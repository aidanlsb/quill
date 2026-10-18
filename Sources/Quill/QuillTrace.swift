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
        // Touch the origin first. Sampling `now` and then lazily initializing
        // `startNanos` makes the unsigned subtract wrap on the first call.
        let origin = startNanos
        return Double(DispatchTime.now().uptimeNanoseconds &- origin) / 1_000_000
    }

    static func event(_ name: StaticString) {
        let ms = millisSinceStart()
        guard enabled else { return }
        os_signpost(.event, log: log, name: name)
        write("quill trace \(name) \(format(ms))\n")
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
        let bytes = Array(line.utf8)
        bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = Darwin.write(STDERR_FILENO, base, buffer.count)
        }
    }
}

/// Averages named spans while `QUILL_PERF=1`. `AppPerf` prints them next to
/// the headline measurements.
@MainActor
enum QuillPerfSplit {
    static let enabled = ProcessInfo.processInfo.environment["QUILL_PERF"] == "1"
    private static var totals: [String: Double] = [:]
    private static var counts: [String: Int] = [:]

    static func add(_ name: String, since began: UInt64) {
        guard enabled else { return }
        let ms = Double(DispatchTime.now().uptimeNanoseconds &- began) / 1_000_000
        totals[name, default: 0] += ms
        counts[name, default: 0] += 1
    }

    static func flush() {
        guard enabled else { return }
        for name in totals.keys.sorted() {
            let count = max(counts[name] ?? 1, 1)
            let avg = (totals[name] ?? 0) / Double(count)
            QuillTrace.write("quill perf \(name)=\(QuillTrace.format(avg))\n")
        }
        totals.removeAll()
        counts.removeAll()
    }
}
