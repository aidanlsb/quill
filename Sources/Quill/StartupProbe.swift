import AppKit
import Darwin
import Foundation
import QuillVim
import os

/// Cold-start probe. A normal launch only reads one immutable flag.
///
/// `QUILL_PERF=1` records time to the first editable frame in the perf log.
/// `/tmp/quill-startup-request` (or `QUILL_STARTUP=1`) asks the process to
/// prove the frame, write JSON, signal a fifo, and exit. `Scripts/quill` goes
/// through Launch Services, which drops the environment, so the request file
/// is how a CLI open is measured.
enum StartupProbe {
    static func begin(_ name: StaticString) -> UInt64 {
        guard StartupLog.shared.tracing else { return 0 }
        os_signpost(.begin, log: StartupLog.signpost, name: name)
        return DispatchTime.now().uptimeNanoseconds
    }

    static func end(_ name: StaticString, _ began: UInt64) {
        guard began != 0, StartupLog.shared.tracing else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let ms = Double(now &- began) / 1_000_000
        let start = QuillTrace.millisSinceStart() - ms
        StartupLog.shared.addSpan(label(name), startMs: start, ms: ms)
        os_signpost(.end, log: StartupLog.signpost, name: name)
    }

    static func mark(_ name: StaticString) {
        guard StartupLog.shared.tracing else { return }
        let ms = QuillTrace.millisSinceStart()
        StartupLog.shared.addMark(label(name), ms: ms)
        os_signpost(.event, log: StartupLog.signpost, name: name)
    }

    static func markOnce(_ name: StaticString) {
        guard StartupLog.shared.tracing else { return }
        guard StartupLog.shared.claimOnce(label(name)) else { return }
        mark(name)
    }

    private static func label(_ name: StaticString) -> String {
        name.withUTF8Buffer { String(decoding: $0, as: UTF8.self) }
    }

    static func arm() {
        guard StartupLog.shared.tracing else { return }
        mark("delegateInit")
        StartupLog.shared.armWatchdog()
    }

    static var recordsDraw: Bool { StartupLog.shared.hookDraw }
    static var editableMilliseconds: Double? { StartupLog.shared.editableMilliseconds }
}

/// Draw facts and the report. The main thread writes; the watchdog reads.
// quill-concurrency: NSLock guards the probe log; the watchdog and the main thread both read it.
private final class StartupLog: @unchecked Sendable {
    static let shared = StartupLog()
    static let signpost = OSLog(subsystem: "com.aidanlsb.Quill", category: .pointsOfInterest)

    /// Spans and marks. Off during the perf suite so keystrokes do not take the log lock.
    let tracing: Bool
    /// Time-to-editable in `QUILL_PERF` and in the exiting probe.
    let wantsEditable: Bool
    /// `draw` records the frame only for the exiting probe. The perf suite does not.
    let hookDraw: Bool
    let exits: Bool
    let expectPath: String?
    let prefix: String
    let outPath: String?
    let fifoPath: String?

    private let lock = NSLock()
    private var finished = false
    private var marks: [(String, Double)] = []
    private var spans: [(String, Double, Double)] = []
    private var once: Set<String> = []
    private var firstDrawMs: Double?
    private var lastDrawLength = -1
    private var lastDrawStyled = false
    private var unstyledDraw = false
    private var keyAccepted = false
    private var editableMs: Double?
    private var readyQueued = false
    private var waiting = ""
    private var focused = false
    private var appActive = false
    private let numer: UInt64
    private let denom: UInt64

    private init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        numer = UInt64(info.numer)
        denom = max(1, UInt64(info.denom))
        let env = ProcessInfo.processInfo.environment
        let request = Self.loadRequest()
        if let request {
            tracing = true
            wantsEditable = true
            hookDraw = true
            exits = true
            expectPath = request.expect
            prefix = request.prefix
            outPath = request.out
            fifoPath = request.fifo
        } else if env["QUILL_STARTUP"] == "1" {
            tracing = true
            wantsEditable = true
            hookDraw = true
            exits = true
            expectPath = nil
            prefix = ""
            outPath = env["QUILL_STARTUP_OUT"]
            fifoPath = env["QUILL_STARTUP_FIFO"]
        } else if env["QUILL_PERF"] == "1", env["QUILL_SMOKE"] != "1" {
            tracing = false
            wantsEditable = true
            hookDraw = false
            exits = false
            expectPath = nil
            prefix = ""
            outPath = nil
            fifoPath = nil
        } else {
            tracing = false
            wantsEditable = false
            hookDraw = false
            exits = false
            expectPath = nil
            prefix = ""
            outPath = nil
            fifoPath = nil
        }
    }

    var editableMilliseconds: Double? {
        lock.lock()
        defer { lock.unlock() }
        return editableMs
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func addSpan(_ name: String, startMs: Double, ms: Double) {
        lock.lock()
        spans.append((name, startMs, ms))
        lock.unlock()
    }

    func addMark(_ name: String, ms: Double) {
        lock.lock()
        marks.append((name, ms))
        lock.unlock()
    }

    func claimOnce(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return once.insert(name).inserted
    }

    func recordDraw(length: Int, styled: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished { return false }
        if length > 0 && !styled { unstyledDraw = true }
        lastDrawLength = length
        lastDrawStyled = styled
        if firstDrawMs == nil {
            firstDrawMs = QuillTrace.millisSinceStart()
        }
        if readyQueued { return false }
        readyQueued = true
        return true
    }

    func clearReadyQueue() {
        lock.lock()
        readyQueued = false
        lock.unlock()
    }

    func drawSnapshot() -> (length: Int, styled: Bool, unstyled: Bool, firstDrawMs: Double?) {
        lock.lock()
        defer { lock.unlock() }
        return (lastDrawLength, lastDrawStyled, unstyledDraw, firstDrawMs)
    }

    func setWaiting(_ reason: String) {
        lock.lock()
        waiting = reason
        lock.unlock()
    }

    func setFocus(key: Bool, active: Bool) {
        lock.lock()
        focused = key
        appActive = active
        lock.unlock()
    }

    func setKeyAccepted(_ accepted: Bool) {
        lock.lock()
        keyAccepted = accepted
        lock.unlock()
    }

    func finish(editableMs: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished { return false }
        finished = true
        self.editableMs = editableMs
        marks.append(("editable", editableMs))
        return true
    }

    func armWatchdog() {
        guard exits else { return }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 12) { [self] in
            let report = self.claimTimeout()
            guard let report else { return }
            self.publish(report, signalNanos: self.machNanos())
            let line = "quill startup watchdog: timed out\n"
            _ = line.withCString { Darwin.write(STDERR_FILENO, $0, strlen($0)) }
            exit(2)
        }
    }

    func publishSuccess() {
        let unstyled: Bool = {
            lock.lock()
            defer { lock.unlock() }
            return unstyledDraw
        }()
        let reason = unstyled ? "unstyled first draw" : ""
        publish(snapshot(ok: !unstyled, reason: reason), signalNanos: machNanos())
    }

    private func claimTimeout() -> Report? {
        lock.lock()
        defer { lock.unlock() }
        if finished { return nil }
        finished = true
        return reportUnlocked(ok: false, reason: "timeout")
    }

    private func snapshot(ok: Bool, reason: String) -> Report {
        lock.lock()
        defer { lock.unlock() }
        return reportUnlocked(ok: ok, reason: reason)
    }

    private func reportUnlocked(ok: Bool, reason: String) -> Report {
        Report(
            ok: ok,
            reason: reason,
            exits: exits,
            expectPath: expectPath,
            marks: marks,
            spans: spans,
            editableMs: editableMs,
            firstDrawMs: firstDrawMs,
            unstyledDraw: unstyledDraw,
            keyAccepted: keyAccepted,
            waiting: waiting,
            focused: focused,
            appActive: appActive
        )
    }

    private func machNanos() -> UInt64 {
        mach_absolute_time() * numer / denom
    }

    private func publish(_ report: Report, signalNanos: UInt64) {
        let object = report.json(signalNanos: signalNanos)
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return }
        if let outPath {
            try? data.write(to: URL(fileURLWithPath: outPath), options: .atomic)
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        QuillTrace.write("quill startup report\n\(text)\n")
        // One byte, after the file is on disk, so the shell's wait is not a poll
        // and a slow reader cannot fill the pipe and stall exit.
        guard let fifoPath else { return }
        let fd = Darwin.open(fifoPath, O_WRONLY | O_NONBLOCK)
        guard fd >= 0 else { return }
        _ = Darwin.write(fd, ".\n", 2)
        Darwin.close(fd)
    }

    private static func loadRequest() -> Request? {
        let path = "/tmp/quill-startup-request"
        guard FileManager.default.fileExists(atPath: path),
              let text = try? String(contentsOfFile: path, encoding: .utf8)
        else { return nil }
        guard let request = Request.parse(text), request.deadline > Date() else {
            try? FileManager.default.removeItem(atPath: path)
            return nil
        }
        try? FileManager.default.removeItem(atPath: path)
        return request
    }
}

private struct Request {
    var deadline: Date
    var fifo: String?
    var out: String?
    var expect: String?
    var prefix: String

    static func parse(_ text: String) -> Request? {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            fields[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        guard fields["quill-startup"] == "1", let raw = fields["deadline"], let seconds = Double(raw) else {
            return nil
        }
        return Request(
            deadline: Date(timeIntervalSince1970: seconds),
            fifo: fields["fifo"],
            out: fields["out"],
            expect: fields["expect"],
            prefix: fields["prefix"] ?? ""
        )
    }
}

private struct Report {
    var ok: Bool
    var reason: String
    var exits: Bool
    var expectPath: String?
    var marks: [(String, Double)]
    var spans: [(String, Double, Double)]
    var editableMs: Double?
    var firstDrawMs: Double?
    var unstyledDraw: Bool
    var keyAccepted: Bool
    var waiting: String
    var focused: Bool
    var appActive: Bool

    func json(signalNanos: UInt64) -> [String: Any] {
        var object: [String: Any] = [
            "ok": ok,
            "reason": reason,
            "case": expectPath == nil ? "cold" : "file",
            "exits": exits,
            "unstyledDraw": unstyledDraw,
            "keyAccepted": keyAccepted,
            "waiting": waiting,
            "focused": focused,
            "active": appActive,
            "signalNanos": String(signalNanos),
            "marks": marks.map { ["name": $0.0, "ms": $0.1] },
            "spans": spans.map { ["name": $0.0, "startMs": $0.1, "ms": $0.2] },
        ]
        if let editableMs { object["launchToEditableMs"] = editableMs }
        if let firstDrawMs { object["launchToDrawMs"] = firstDrawMs }
        if let key = marks.first(where: { $0.0 == "keyWindow" })?.1 {
            object["launchToKeyMs"] = key
        }
        return object
    }
}

@MainActor
enum StartupUI {
    weak static var model: AppModel?
    private static var retrying = false
    private static var notifications = false

    static func attach(_ model: AppModel) {
        guard StartupLog.shared.wantsEditable else { return }
        self.model = model
    }

    static func noteKeyWindow() {
        guard StartupLog.shared.wantsEditable else { return }
        StartupProbe.mark("keyWindow")
        considerReady()
    }

    static func noteContent() {
        guard StartupLog.shared.wantsEditable else { return }
        StartupProbe.mark("contentInstalled")
        considerReady()
    }

    private static var inReady = false

    static func considerReady() {
        let log = StartupLog.shared
        guard log.wantsEditable, !log.isFinished, !inReady else { return }
        inReady = true
        log.clearReadyQueue()
        defer {
            inReady = false
            if log.exits, !log.isFinished { scheduleRetry() }
        }
        guard let model, let view = model.editor, view.engine != nil, let window = view.window else {
            log.setWaiting("editor")
            return
        }
        if log.exits {
            let needsFocus = !window.isVisible || !window.isKeyWindow || window.firstResponder !== view
            if needsFocus || (log.expectPath != nil && !NSApplication.shared.isActive) {
                prepare(window, view: view)
            }
        }

        if let expect = log.expectPath {
            let got = model.document.url?.standardizedFileURL.path
            let want = URL(fileURLWithPath: expect).standardizedFileURL.path
            if got != want {
                log.setWaiting("file")
                return
            }
            if !log.prefix.isEmpty, !model.engine.text.hasPrefix(log.prefix) {
                log.setWaiting("prefix")
                return
            }
        }

        let length = (view.string as NSString).length
        if length > 0, !view.didApplyDocumentStyle {
            log.setWaiting("style")
            return
        }
        if log.hookDraw {
            if !drawMatches(length, log: log, view: view, window: window) {
                log.setWaiting("draw")
                return
            }
        } else {
            view.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
            view.displayIfNeeded()
        }
        if length > 0, log.expectPath != nil, !headingIsStyled(view) {
            log.setWaiting("heading")
            return
        }

        if !window.isVisible {
            log.setWaiting("visible")
            return
        }
        // A direct binary launch from CI is not activated, so the window can be
        // on screen and still not key. `quill <file>` goes through `open -a`,
        // which does activate, and that case has to come forward.
        let foreground = log.expectPath != nil
        if foreground {
            if !window.isKeyWindow {
                log.setWaiting("key")
                return
            }
            if window.screen?.visibleFrame.intersects(window.frame) != true {
                log.setWaiting("screen")
                return
            }
            if window.firstResponder !== view {
                log.setWaiting("responder")
                return
            }
            if !NSApplication.shared.isActive {
                log.setWaiting("active")
                return
            }
        }
        log.setFocus(key: window.isKeyWindow, active: NSApplication.shared.isActive)

        if !view.startupDidAcceptKey {
            let cursor = view.engine.cursor
            let empty = model.engine.text.isEmpty
            let before = view.startupKeyEvents
            view.startupCountKeys = true
            type(empty ? "i<Esc>" : "l", on: view)
            view.startupCountKeys = false
            let moved = !empty && view.engine.cursor > cursor
            let accepted = view.startupKeyEvents > before && (empty || moved)
            view.startupDidAcceptKey = accepted
            log.setKeyAccepted(accepted)
            if !accepted {
                log.setWaiting("keystroke")
                return
            }
        }

        let ms = QuillTrace.millisSinceStart()
        guard log.finish(editableMs: ms) else { return }
        guard log.exits else { return }
        log.publishSuccess()
        exit(0)
    }

    private static func prepare(_ window: NSWindow, view: VimTextView) {
        AppActivation.prepare()
        if !window.isVisible || !window.isKeyWindow {
            AppActivation.bringForward()
            window.makeKeyAndOrderFront(nil)
        }
        if window.firstResponder !== view {
            window.makeFirstResponder(view)
        }
        if !notifications {
            notifications = true
            let center = NotificationCenter.default
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                // The main queue is the main thread. assumeIsolated hops onto the main actor.
                MainActor.assumeIsolated { considerReady() }
            }
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { considerReady() }
            }
        }
    }

    private static func drawMatches(_ length: Int, log: StartupLog, view: VimTextView, window: NSWindow) -> Bool {
        let draw = log.drawSnapshot()
        if draw.length == length, length == 0 || draw.styled { return true }
        view.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        view.displayIfNeeded()
        let again = log.drawSnapshot()
        return again.length == length && (length == 0 || again.styled)
    }

    private static func headingIsStyled(_ view: VimTextView) -> Bool {
        guard let storage = view.textStorage, storage.length > 1 else { return false }
        let ns = storage.string as NSString
        let hash = ns.range(of: "# ")
        guard hash.location != NSNotFound, hash.location < storage.length else { return false }
        guard let heading = storage.attribute(.font, at: hash.location, effectiveRange: nil) as? NSFont,
              let body = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else { return false }
        return heading.pointSize > body.pointSize + 0.5
    }

    private static func scheduleRetry() {
        guard !retrying else { return }
        retrying = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(2)) {
            retrying = false
            considerReady()
        }
    }

    private static func type(_ notation: String, on view: VimTextView) {
        for event in KeyEvent.parse(notation) {
            let chars: String
            let code: UInt16
            switch event.key {
            case .character(let ch): (chars, code) = (String(ch), 0)
            case .escape: (chars, code) = ("\u{1b}", 53)
            default: continue
            }
            guard let ns = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: view.window?.windowNumber ?? 0,
                context: nil,
                characters: chars,
                charactersIgnoringModifiers: chars,
                isARepeat: false,
                keyCode: code
            ) else { continue }
            view.keyDown(with: ns)
        }
    }
}

extension StartupProbe {
    /// Called from `draw`. Records the frame and wakes the readiness check.
    static func noteDrew(length: Int, styled: Bool) {
        guard StartupLog.shared.recordDraw(length: length, styled: styled) else { return }
        DispatchQueue.main.async {
            // The main queue is the main thread. assumeIsolated hops onto the main actor.
            MainActor.assumeIsolated { StartupUI.considerReady() }
        }
    }
}
