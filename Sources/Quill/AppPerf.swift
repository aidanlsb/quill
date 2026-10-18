import AppKit
import Foundation
import QuillFS
import QuillMarkdown
import QuillSearch
import QuillVim
import QuillWorkspace

/// `QUILL_PERF=1` measures launch, editing, and picker work, prints
/// `quill perf <name>=<ms>` lines, and exits. It does not wait on `onAppear`.
@MainActor
enum AppPerf {
    private static var keyWindowMs: Double?
    private static var started = false

    static func noteKeyWindow() {
        guard ProcessInfo.processInfo.environment["QUILL_PERF"] == "1" else { return }
        if keyWindowMs == nil {
            keyWindowMs = QuillTrace.millisSinceStart()
        }
    }

    static func launchDidFinish() {
        guard !started else { return }
        guard ProcessInfo.processInfo.environment["QUILL_PERF"] == "1" else { return }
        guard ProcessInfo.processInfo.environment["QUILL_SMOKE"] != "1" else { return }
        started = true
        let finish = QuillTrace.millisSinceStart()
        let deadline = Date().addingTimeInterval(1.5)
        while keyWindowMs == nil, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        run(launchToFinishMs: finish)
        exit(0)
    }

    private static func run(launchToFinishMs: Double) {
        emit("launchToFinishMs", launchToFinishMs)
        emit("launchToKeyMs", keyWindowMs ?? -1)

        let big = sample(lines: 10_000)
        let full = millis {
            _ = MarkdownTokenizer(text: big)
        }
        var tokenizer = MarkdownTokenizer(text: big)
        var edited = big
        edited.removeLast()
        edited.append("!")
        let dirty = big.utf16.count - 2
        let edit = millis {
            _ = tokenizer.apply(start: dirty, removedUTF16: 1, replacement: "!")
        }
        emit("styleFullMs", full)
        emit("styleEditMs", edit)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-perf-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try "vendor/\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
            let vendor = root.appendingPathComponent("vendor", isDirectory: true)
            try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
            for index in 0..<400 {
                try "note \(index)\n".write(to: root.appendingPathComponent("note-\(index).md"), atomically: true, encoding: .utf8)
                try "skip \(index)\n".write(to: vendor.appendingPathComponent("skip-\(index).md"), atomically: true, encoding: .utf8)
            }
            let walkAll = millis {
                var count = 0
                if let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) {
                    while enumerator.nextObject() != nil { count += 1 }
                }
                _ = count
            }
            emit("ignoreWalkAllMs", walkAll)
            let picker = millis {
                let ignore = IgnoreRules.load(from: root)
                _ = FileWalk.files(in: root, ignore: ignore).count
            }
            emit("pickerOpenMs", picker)
            let names = (0..<400).map { "note-\($0).md" }
            let engine = PickerEngine(source: names.map { PickerItem(title: $0, payload: $0) })
            let filter = millis {
                _ = engine.handle(.character("n"))
                _ = engine.handle(.character("1"))
                _ = engine.handle(.character("2"))
            }
            emit("pickerKeyMs", filter / 3.0)

            let grep = millis {
                _ = ContentSearch.search(root: root, query: "note", ignore: IgnoreRules.load(from: root))
            }
            emit("grepMs", grep)

            let directory = millis {
                _ = try? DirectoryListing.snapshot(of: root)
            }
            emit("directoryMs", directory)

            let file = root.appendingPathComponent("large.md")
            try edited.write(to: file, atomically: true, encoding: .utf8)
            let read = millis {
                _ = try? TextCodec.decode(Data(contentsOf: file))
            }
            emit("fileReadMs", read)
        } catch {
            QuillTrace.write("quill perf error \(error.localizedDescription)\n")
        }

        let session = host(edited)
        let view = session.view
        let sync = millis {
            view.syncFromEngine()
        }
        emit("textSyncMs", sync)
        view.engine.mode = .insert
        let typing = millis {
            for _ in 0..<20 {
                let result = view.engine.handle(KeyEvent(.character("a")))
                view.applyResult(result)
            }
        }
        emit("keystrokeMs", typing / 20.0)
        view.engine.mode = .normal
        let motion = millis {
            for _ in 0..<40 {
                let result = view.engine.handle(KeyEvent(.character("j")))
                view.applyResult(result)
            }
        }
        emit("scrollMs", motion / 40.0)
        let layout = millis {
            view.layoutAdapter.ensureFullLayout()
        }
        emit("layoutFullMs", layout)
        session.window.orderOut(nil)

        try? FileManager.default.removeItem(at: root)
        QuillTrace.write("quill perf done\n")
    }

    private static func sample(lines: Int) -> String {
        (0..<lines).map { "Line \($0) with [[note]] and `code` and **bold**.\n" }.joined()
    }

    private static func host(_ text: String) -> (view: VimTextView, window: NSWindow) {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        scroll.hasVerticalScroller = true
        let tv = VimTextView(usingTextLayoutManager: true)
        tv.commonInit()
        let engine = Engine(text: text)
        tv.engine = engine
        engine.layout = tv.layoutAdapter
        scroll.documentView = tv
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        return (tv, window)
    }

    private static func millis(_ body: () -> Void) -> Double {
        let began = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds &- began) / 1_000_000
    }

    private static func emit(_ name: String, _ ms: Double) {
        QuillTrace.write("quill perf \(name)=\(QuillTrace.format(ms))\n")
    }
}
