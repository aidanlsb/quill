import AppKit
import Darwin
import Foundation
import QuillVim
import QuillWorkspace

/// `QUILL_BENCH=1` measures the editing path and writes JSON to `QUILL_BENCH_OUT`.
///
/// `QUILL_BENCH_PHASE=launch` records only the cold start. `suite` (the default)
/// opens markdown fixtures, types, moves, restyles, resizes, scrolls, and opens
/// the directory buffer and the pickers. The shell repeats processes; this
/// process repeats the work inside one launch and reports median / p95 / p99.
@MainActor
enum AppBench {
    private static var keyWindowMs: Double?
    private static var started = false
    private static var stats: [String: [Double]] = [:]
    private static var peakMB = 0.0
    private static var editorWindow: NSWindow?
    private static var editorScroll: NSScrollView?
    private static var editorView: VimTextView?

    static func noteKeyWindow() {
        guard ProcessInfo.processInfo.environment["QUILL_BENCH"] == "1" else { return }
        if keyWindowMs == nil {
            keyWindowMs = QuillTrace.millisSinceStart()
        }
    }

    static func launchDidFinish() {
        guard !started else { return }
        let env = ProcessInfo.processInfo.environment
        guard env["QUILL_BENCH"] == "1" else { return }
        guard env["QUILL_SMOKE"] != "1", env["QUILL_PERF"] != "1" else { return }
        started = true
        let phase = env["QUILL_BENCH_PHASE"] ?? "suite"
        armWatchdog(seconds: phase == "launch" ? 45 : 20 * 60)
        let finish = QuillTrace.millisSinceStart()
        let deadline = Date().addingTimeInterval(3)
        while keyWindowMs == nil, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        guard let key = keyWindowMs else {
            fail("key window did not appear (launchToFinishMs=\(QuillTrace.format(finish)))")
        }
        if phase == "launch" {
            add("launchToKeyMs", [key])
            writeResult(phase: "launch")
            exit(0)
        }
        runSuite()
        writeResult(phase: "suite")
        exit(0)
    }

    // MARK: Suite

    private static func runSuite() {
        let env = ProcessInfo.processInfo.environment
        let quick = env["QUILL_BENCH_QUICK"] == "1"
        guard let root = env["QUILL_BENCH_FIXTURES"], !root.isEmpty else {
            fail("QUILL_BENCH_FIXTURES is not set")
        }
        let fixtures = URL(fileURLWithPath: root, isDirectory: true)
        let prose1k = fixtures.appendingPathComponent("prose-1k.md")
        let prose50k = fixtures.appendingPathComponent("prose-50k.md")
        let prose500k = fixtures.appendingPathComponent("prose-500k.md")
        let heavy = fixtures.appendingPathComponent("heavy.md")
        let repo = fixtures.appendingPathComponent("repo", isDirectory: true)
        requireFile(prose1k)
        requireFile(heavy)
        if !quick {
            requireFile(prose50k)
            requireFile(prose500k)
        }

        let session = host()
        editorWindow = session.window
        editorScroll = session.scroll
        editorView = session.view
        sampleSteady()

        let openWarm = quick ? 0 : 1
        add("open1kMs", tryOpen(session.view, prose1k, warmup: openWarm, count: quick ? 2 : 5))
        if !quick {
            add("open50kMs", tryOpen(session.view, prose50k, warmup: 1, count: 3))
        }
        add("openHeavyMs", tryOpen(session.view, heavy, warmup: openWarm, count: quick ? 1 : 3))
        restyle(session.view, quick: quick)
        add("resizeMs", resizeSamples(session, warmup: quick ? 0 : 1, count: quick ? 2 : 6))

        let huge = quick ? prose1k : prose500k
        if !quick {
            let opened = tryTimedOpen(session.view, huge)
            add("open500kColdMs", [opened.cold])
            add("open500kMs", opened.steady)
        }
        let buffer = session.view
        let lines = buffer.engine.buffer.lineCount
        let top = 0
        let mid = contentLine(near: lines / 2, in: buffer)
        let end = contentLine(near: max(0, lines - 1), in: buffer)
        let keyCount = quick ? 4 : 20
        let keyWarm = quick ? 1 : 2
        add("keyInsertTopMs", keystrokes(buffer, line: top, insert: true, warmup: keyWarm, count: keyCount))
        add("keyInsertMidMs", keystrokes(buffer, line: mid, insert: true, warmup: keyWarm, count: keyCount))
        add("keyInsertEndMs", keystrokes(buffer, line: end, insert: true, warmup: keyWarm, count: keyCount))
        add("keyNormalTopMs", keystrokes(buffer, line: top, insert: false, warmup: keyWarm, count: keyCount))
        add("keyNormalMidMs", keystrokes(buffer, line: mid, insert: false, warmup: keyWarm, count: keyCount))
        add("keyNormalEndMs", keystrokes(buffer, line: end, insert: false, warmup: keyWarm, count: keyCount))

        // Repeated j/k/w stay near the top. The first step only extends layout
        // past the screen. G, gg, and search are the jumps through the huge note.
        let motionCount = quick ? 4 : 20
        let motionWarm = quick ? 1 : 2
        let motionLine = contentLine(near: 40, in: buffer)
        place(buffer, line: motionLine)
        add("motionJMs", repeatKey(buffer, "j", warmup: motionWarm, count: motionCount))
        place(buffer, line: motionLine)
        add("motionKMs", repeatKey(buffer, "k", warmup: motionWarm, count: motionCount))
        place(buffer, line: motionLine)
        add("motionWMs", repeatKey(buffer, "w", warmup: motionWarm, count: motionCount))

        place(buffer, line: top)
        let firstG = millis { press(buffer, .character("G")) }
        add("motionGFirstMs", [firstG])
        let gCount = quick ? 1 : 2
        var gSamples: [Double] = []
        var ggSamples: [Double] = []
        for _ in 0..<gCount {
            ggSamples.append(millis { pressGG(buffer) })
            gSamples.append(millis { press(buffer, .character("G")) })
        }
        add("motionGMs", gSamples)
        add("motionGgMs", ggSamples)

        let searchCount = quick ? 1 : 3
        var searches: [Double] = []
        for index in 0..<(searchCount + 1) {
            buffer.engine.mode = .normal
            press(buffer, .escape)
            buffer.engine.moveCursor(to: 0)
            let ms = millis { pressSearch(buffer) }
            if buffer.engine.cursor < buffer.engine.buffer.count / 2 {
                fail("search did not reach quill-bench-end (cursor \(buffer.engine.cursor))")
            }
            if index >= 1 { searches.append(ms) }
        }
        add("motionSearchMs", searches)

        place(buffer, line: mid)
        let linesBefore = buffer.engine.buffer.lineCount
        let editCount = quick ? 1 : 4
        var deletes: [Double] = []
        var undos: [Double] = []
        var redos: [Double] = []
        for index in 0..<(editCount + 1) {
            let dd = millis { pressDD(buffer) }
            let undo = millis { press(buffer, .character("u")) }
            let redo = millis { press(buffer, .ctrl("r")) }
            press(buffer, .character("u"))
            if buffer.engine.buffer.lineCount != linesBefore {
                fail("dd/undo did not restore the line count")
            }
            if index >= 1 {
                deletes.append(dd)
                undos.append(undo)
                redos.append(redo)
            }
        }
        add("motionDdMs", deletes)
        add("motionUndoMs", undos)
        add("motionRedoMs", redos)

        place(buffer, line: top)
        let scrollCount = quick ? 4 : 20
        var scrolls: [Double] = []
        for index in 0..<(scrollCount + 1) {
            let ms = millis { buffer.consumeScroll(deltaY: -160, precise: true) }
            if index >= 1 { scrolls.append(ms) }
        }
        add("scrollMs", scrolls)
        noteMemory()
        releaseEditor()

        let model = AppModel()
        model.engine.leaderKey = " "
        model.engine.leaderBindings["sf"] = .findFiles
        model.engine.leaderBindings["sg"] = .liveGrep
        model.engine.formatTablesOnInsertLeave = false
        let wide = repo.appendingPathComponent("wide", isDirectory: true)
        let wideB = repo.appendingPathComponent("wide-b", isDirectory: true)
        requireFile(wide)
        requireFile(wideB)
        let dirCount = quick ? 1 : 5
        var directories: [Double] = []
        for index in 0..<(dirCount + 1) {
            let url = index % 2 == 0 ? wide : wideB
            let ms = millis { model.open(url: url) }
            if !model.isDirectory {
                fail("directory open did not stick: \(model.message)")
            }
            if index == 0 {
                add("directoryColdMs", [ms])
            } else {
                directories.append(ms)
            }
        }
        add("directoryMs", directories)

        model.open(url: repo)
        if !model.isDirectory {
            fail("repo root did not open as a directory: \(model.message)")
        }
        let pickerCount = quick ? 1 : 5
        measurePicker(model, count: pickerCount)
        noteMemory()
        add("rssSteadyMb", steadyHeld)
        add("rssPeakMb", [peakMB])
    }

    private static var steadyHeld: [Double] = []

    private static func restyle(_ view: VimTextView, quick: Bool) {
        let text = view.engine.text
        guard let prose = utf16Offset(of: "paragraph stays", in: text) else {
            fail("heavy fixture has no prose paragraph")
        }
        guard let table = utf16Offset(of: "| alpha |", in: text) else {
            fail("heavy fixture has no table")
        }
        let count = quick ? 2 : 16
        add("restyleProseMs", editSamples(view, at: prose + 8, count: count))
        add("restyleTableMs", editSamples(view, at: table + 3, count: count))
    }

    private static func editSamples(_ view: VimTextView, at offset: Int, count: Int) -> [Double] {
        view.engine.mode = .normal
        view.engine.moveCursor(to: offset)
        view.syncFromEngine()
        view.engine.mode = .insert
        var samples: [Double] = []
        let total = count + 1
        for index in 0..<total {
            let ms = millis {
                let result = view.engine.handle(KeyEvent(.character("x")))
                view.applyResult(result)
            }
            let back = view.engine.handle(KeyEvent(.backspace))
            view.applyResult(back)
            if index >= 1 { samples.append(ms) }
        }
        view.engine.mode = .normal
        return samples
    }

    private static func measurePicker(_ model: AppModel, count: Int) {
        closePicker(model)
        let cold = millis {
            leader(model, "s", "f")
            if !wait(until: Date().addingTimeInterval(60), ready: { filesReady(model) }) {
                fail("file picker did not fill")
            }
        }
        add("pickerSfColdMs", [cold])
        if model.picker?.items.isEmpty != false {
            fail("file picker opened with no files")
        }
        var steady: [Double] = []
        var keys: [Double] = []
        for _ in 0..<count {
            closePicker(model)
            let ms = millis {
                leader(model, "s", "f")
                if !wait(until: Date().addingTimeInterval(60), ready: { filesReady(model) }) {
                    fail("file picker did not fill")
                }
            }
            steady.append(ms)
            let key = millis { model.handlePicker(.character("n")) }
            keys.append(key)
        }
        add("pickerSfMs", steady)
        add("pickerSfKeyMs", keys)
        closePicker(model)

        let coldGrep = millis { runGrep(model) }
        add("pickerSgColdMs", [coldGrep])
        var greps: [Double] = []
        for _ in 0..<count {
            closePicker(model)
            greps.append(millis { runGrep(model) })
        }
        add("pickerSgMs", greps)
        closePicker(model)
    }

    private static func runGrep(_ model: AppModel) {
        leader(model, "s", "g")
        if model.picker == nil {
            fail("grep picker did not open")
        }
        for ch in "quillbench-needle" {
            model.handlePicker(.character(ch))
        }
        if !wait(until: Date().addingTimeInterval(60), ready: { grepReady(model) }) {
            fail("grep picker found nothing for quillbench-needle")
        }
    }

    private static func filesReady(_ model: AppModel) -> Bool {
        guard let picker = model.picker else { return false }
        return !picker.items.isEmpty
    }

    private static func grepReady(_ model: AppModel) -> Bool {
        guard let picker = model.picker else { return false }
        return picker.items.contains {
            $0.title.contains("quillbench-needle") || $0.subtitle.contains("quillbench-needle")
        }
    }

    private static func leader(_ model: AppModel, _ a: Character, _ b: Character) {
        model.engine.mode = .normal
        press(model, .character(" "))
        press(model, .character(a))
        press(model, .character(b))
    }

    private static func press(_ model: AppModel, _ key: Key) {
        let result = model.engine.handle(KeyEvent(key))
        model.handleEngineResult(result)
    }

    private static func closePicker(_ model: AppModel) {
        if model.picker == nil { return }
        model.handlePicker(.escape)
        if model.picker != nil {
            model.handlePicker(.escape)
        }
        if model.picker != nil {
            model.picker = nil
            model.pickerKind = nil
        }
    }

    // MARK: Editor driving

    private static func host() -> (view: VimTextView, scroll: NSScrollView, window: NSWindow) {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 960, height: 760))
        scroll.hasVerticalScroller = true
        let tv = VimTextView.make()
        tv.commonInit()
        let engine = Engine(text: "")
        tv.engine = engine
        engine.layout = tv.layoutAdapter
        engine.formatTablesOnInsertLeave = false
        scroll.documentView = tv
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 760),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        tv.columnWidth = 640
        tv.applyTheme(QuillTheme.current(), focus: false)
        return (tv, scroll, window)
    }

    private static func releaseEditor() {
        editorView?.engine.load(text: "")
        editorView?.syncFromEngine()
        editorWindow?.orderOut(nil)
        editorWindow = nil
        editorScroll = nil
        editorView = nil
    }

    private static func tryOpen(_ view: VimTextView, _ url: URL, warmup: Int, count: Int) -> [Double] {
        var samples: [Double] = []
        for index in 0..<(warmup + count) {
            let ms = millis { openInto(view, url: url) }
            if index >= warmup { samples.append(ms) }
        }
        return samples
    }

    private static func tryTimedOpen(_ view: VimTextView, _ url: URL) -> (cold: Double, steady: [Double]) {
        let cold = millis { openInto(view, url: url) }
        var steady: [Double] = []
        for _ in 0..<2 {
            steady.append(millis { openInto(view, url: url) })
        }
        return (cold, steady)
    }

    private static func openInto(_ view: VimTextView, url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let decoded = try TextCodec.decode(data)
            view.engine.load(text: decoded.text)
            view.engine.formatTablesOnInsertLeave = false
            view.syncFromEngine()
            noteMemory()
        } catch {
            fail("open \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private static func keystrokes(
        _ view: VimTextView,
        line: Int,
        insert: Bool,
        warmup: Int,
        count: Int
    ) -> [Double] {
        place(view, line: line)
        view.engine.mode = insert ? .insert : .normal
        var samples: [Double] = []
        let width = view.engine.buffer.count
        for index in 0..<(warmup + count) {
            let ms: Double
            if insert {
                ms = millis {
                    let result = view.engine.handle(KeyEvent(.character("a")))
                    view.applyResult(result)
                }
                let back = view.engine.handle(KeyEvent(.backspace))
                view.applyResult(back)
            } else {
                ms = millis {
                    let result = view.engine.handle(KeyEvent(.character("x")))
                    view.applyResult(result)
                }
                let undo = view.engine.handle(KeyEvent(.character("u")))
                view.applyResult(undo)
            }
            if view.engine.buffer.count != width {
                fail("keystroke did not restore the buffer (\(width) -> \(view.engine.buffer.count))")
            }
            if index >= warmup { samples.append(ms) }
        }
        view.engine.mode = .normal
        return samples
    }

    private static func repeatKey(_ view: VimTextView, _ ch: Character, warmup: Int, count: Int) -> [Double] {
        var samples: [Double] = []
        for index in 0..<(warmup + count) {
            let ms = millis { press(view, .character(ch)) }
            if index >= warmup { samples.append(ms) }
        }
        return samples
    }

    private static func press(_ view: VimTextView, _ key: Key) {
        let result = view.engine.handle(KeyEvent(key))
        view.applyResult(result)
    }

    private static func pressGG(_ view: VimTextView) {
        press(view, .character("g"))
        press(view, .character("g"))
    }

    private static func pressDD(_ view: VimTextView) {
        press(view, .character("d"))
        press(view, .character("d"))
    }

    private static func pressSearch(_ view: VimTextView) {
        press(view, .character("/"))
        for ch in "quill-bench-end" {
            press(view, .character(ch))
        }
        press(view, .enter)
    }

    private static func place(_ view: VimTextView, line: Int) {
        let index = contentLine(near: line, in: view)
        let start = view.engine.buffer.lineStarts[index]
        let end = view.engine.buffer.lineEnd(at: index)
        var offset = start
        if end >= start + 2 {
            offset = start + 2
        }
        view.engine.mode = .normal
        // Drop a half-parsed operator or search so the next sample starts clean.
        press(view, .escape)
        view.engine.moveCursor(to: offset)
        view.syncFromEngine()
    }

    private static func contentLine(near line: Int, in view: VimTextView) -> Int {
        let count = view.engine.buffer.lineCount
        guard count > 0 else { return 0 }
        var index = min(max(0, line), count - 1)
        var step = 0
        while step < 40 {
            let start = view.engine.buffer.lineStarts[index]
            let end = view.engine.buffer.lineEnd(at: index)
            if end - start >= 4 { return index }
            if index + 1 >= count { break }
            index += 1
            step += 1
        }
        return min(max(0, line), count - 1)
    }

    private static func resizeSamples(
        _ session: (view: VimTextView, scroll: NSScrollView, window: NSWindow),
        warmup: Int,
        count: Int
    ) -> [Double] {
        let widths: [CGFloat] = [880, 1400]
        var samples: [Double] = []
        for index in 0..<(warmup + count) {
            let width = widths[index % widths.count]
            let ms = millis {
                let size = NSSize(width: width, height: 760)
                session.window.setContentSize(size)
                session.scroll.setFrameSize(size)
                session.scroll.tile()
                session.view.updateInsets()
                session.view.layoutSubtreeIfNeeded()
            }
            if index >= warmup { samples.append(ms) }
            noteMemory()
        }
        return samples
    }

    // MARK: Memory

    /// Idle RSS before the huge note is loaded. Measuring after the note is
    /// freed stays near the peak: the allocator keeps the pages.
    private static func sampleSteady() {
        var samples: [Double] = []
        for _ in 0..<5 {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            let mb = rssMB()
            samples.append(mb)
            if mb > peakMB { peakMB = mb }
        }
        steadyHeld = samples
    }

    private static func noteMemory() {
        let mb = rssMB()
        if mb > peakMB { peakMB = mb }
    }

    private static func rssMB() -> Double {
        let bytes = rssBytes()
        if bytes == 0 {
            fail("task_info did not report resident size")
        }
        return Double(bytes) / 1024 / 1024
    }

    private static func rssBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if kr != KERN_SUCCESS { return 0 }
        return UInt64(info.resident_size)
    }

    // MARK: Timing and output

    private static func millis(_ body: () -> Void) -> Double {
        autoreleasepool {
            let began = DispatchTime.now().uptimeNanoseconds
            body()
            return Double(DispatchTime.now().uptimeNanoseconds &- began) / 1_000_000
        }
    }

    private static func add(_ name: String, _ samples: [Double]) {
        if samples.isEmpty {
            fail("\(name) produced no samples")
        }
        stats[name] = samples
        let mid = percentile(samples, 0.50)
        QuillTrace.write("quill bench \(name)=\(QuillTrace.format(mid))\n")
    }

    private static func percentile(_ samples: [Double], _ p: Double) -> Double {
        let sorted = samples.sorted()
        if sorted.count == 1 { return sorted[0] }
        let rank = p * Double(sorted.count - 1)
        let lo = Int(rank)
        let hi = min(lo + 1, sorted.count - 1)
        let fraction = rank - Double(lo)
        return sorted[lo] * (1 - fraction) + sorted[hi] * fraction
    }

    private static func writeResult(phase: String) {
        guard let path = ProcessInfo.processInfo.environment["QUILL_BENCH_OUT"], !path.isEmpty else {
            fail("QUILL_BENCH_OUT is not set")
        }
        let env = ProcessInfo.processInfo.environment
        var parts: [String] = []
        parts.append("{")
        parts.append("  \"version\": 1,")
        parts.append("  \"phase\": \(jsonString(phase)),")
        parts.append("  \"lowerIsBetter\": true,")
        parts.append("  \"sha\": \(jsonString(env["QUILL_BENCH_SHA"] ?? "")),")
        parts.append("  \"host\": {")
        parts.append("    \"os\": \(jsonString(ProcessInfo.processInfo.operatingSystemVersionString)),")
        parts.append("    \"model\": \(jsonString(hardwareModel())),")
        parts.append("    \"name\": \(jsonString(ProcessInfo.processInfo.hostName))")
        parts.append("  },")
        parts.append("  \"metrics\": {")
        let names = stats.keys.sorted()
        for (index, name) in names.enumerated() {
            let samples = stats[name] ?? []
            let comma = index + 1 == names.count ? "" : ","
            let line = "    \(jsonString(name)): {\"median\": \(fmt(percentile(samples, 0.50))), \"p95\": \(fmt(percentile(samples, 0.95))), \"p99\": \(fmt(percentile(samples, 0.99))), \"n\": \(samples.count)}\(comma)"
            parts.append(line)
        }
        parts.append("  }")
        parts.append("}")
        parts.append("")
        let json = parts.joined(separator: "\n")
        do {
            try Data(json.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            fail("write \(path): \(error.localizedDescription)")
        }
        QuillTrace.write("quill bench done\n")
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    private static func jsonString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }

    private static func hardwareModel() -> String {
        var size = 0
        if sysctlbyname("hw.model", nil, &size, nil, 0) != 0 || size <= 0 { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        if sysctlbyname("hw.model", &bytes, &size, nil, 0) != 0 { return "" }
        return String(cString: bytes)
    }

    private static func utf16Offset(of needle: String, in text: String) -> Int? {
        guard let range = text.range(of: needle) else { return nil }
        let utf16 = text.utf16
        guard let lower = range.lowerBound.samePosition(in: utf16) else { return nil }
        return utf16.distance(from: utf16.startIndex, to: lower)
    }

    private static func requireFile(_ url: URL) {
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            fail("missing fixture \(url.path)")
        }
    }

    private static func wait(until deadline: Date, ready: () -> Bool) -> Bool {
        while !ready(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return ready()
    }

    private static func armWatchdog(seconds: Double) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
            QuillTrace.write("quill bench watchdog: exiting 2 after \(Int(seconds))s\n")
            exit(2)
        }
    }

    private static func fail(_ message: String) -> Never {
        QuillTrace.write("quill bench error \(message)\n")
        exit(1)
    }
}
