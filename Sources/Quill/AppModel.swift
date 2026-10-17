import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers
import QuillFS
import QuillLSP
import QuillSearch
import QuillVim

@MainActor
final class AppModel: ObservableObject {
    let engine = Engine(clipboard: PasteboardClipboard())
    let config = QuillConfig.load()

    @Published var title = "Untitled"
    @Published var status = "NORMAL"
    @Published var message = ""
    @Published var modified = false
    @Published var focusMode = false
    @Published var theme = QuillTheme.current()
    @Published var isDirectory = false
    @Published var hoverText: String?
    @Published var picker: PickerEngine?
    @Published var pickerKind: PickerKind?
    @Published var pendingOps: [FSOperation] = []
    @Published var showConfirm = false
    @Published var completions: [String] = []
    @Published var diagnostics: [Diagnostic] = []

    enum PickerKind { case files, grep }

    private(set) var fileURL: URL?
    private(set) var rootURL: URL
    private(set) var directorySnapshot: DirectorySnapshot?
    private var usesCRLF = false
    private var lsp: LSPClient?
    private var docVersion = 1
    private var fsClipboard: [DirEntry] = []
    private var appearanceObserver: NSKeyValueObservation?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        rootURL = home
        config.apply(to: engine)
        appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.theme = QuillTheme.current(columnCharacters: self?.config.columnWidth ?? 76) }
        }
        theme = QuillTheme.current(columnCharacters: config.columnWidth)
    }

    var modeName: String { engine.mode.displayName }

    func open(url: URL) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            openDirectory(url)
            rootURL = url
            return
        }
        do {
            let data = try Data(contentsOf: url)
            var text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            usesCRLF = text.contains("\r\n")
            text = text.replacingOccurrences(of: "\r\n", with: "\n")
            engine.load(text: text)
            fileURL = url
            rootURL = url.deletingLastPathComponent()
            isDirectory = false
            engine.openOnEnter = false
            directorySnapshot = nil
            title = url.lastPathComponent
            modified = false
            startLSPIfNeeded()
            lsp?.didOpen(uri: url.absoluteString, languageId: "markdown", version: 1, text: engine.text)
            docVersion = 1
            refreshStatus()
        } catch {
            message = error.localizedDescription
        }
    }

    func openDirectory(_ url: URL) {
        do {
            captureDirectoryYank()
            let snap = try DirectoryListing.snapshot(of: url)
            directorySnapshot = snap
            engine.load(text: DirectoryListing.render(snap))
            engine.openOnEnter = true
            isDirectory = true
            fileURL = url
            rootURL = url
            title = url.lastPathComponent + "/"
            modified = false
            refreshStatus()
        } catch {
            message = error.localizedDescription
        }
    }

    func newUntitled() {
        engine.load(text: "")
        fileURL = nil
        isDirectory = false
        engine.openOnEnter = false
        title = "Untitled"
        modified = false
        refreshStatus()
    }

    func handleEngineResult(_ result: EngineResult) {
        modified = engine.isModified
        status = engine.mode.displayName
        if !engine.statusMessage.isEmpty {
            message = engine.statusMessage
        }
        if engine.mode == .commandLine || engine.mode == .search {
            message = engine.commandLine
        }
        if result.didChangeText {
            if isDirectory {
                captureDirectoryYank()
            } else {
                docVersion += 1
                if let url = fileURL {
                    lsp?.didChange(uri: url.absoluteString, version: docVersion, text: engine.text)
                }
                updateWikilinkCompletion()
            }
        }
        for action in result.actions {
            perform(action)
        }
        requestHover()
        refreshStatus()
    }

    func perform(_ action: HostAction) {
        switch action {
        case .write:
            save()
        case .quit:
            NSApp.keyWindow?.close()
        case .writeQuit:
            save()
            if !isDirectory || pendingOps.isEmpty {
                NSApp.keyWindow?.close()
            }
        case .goToDefinition:
            goToDefinition()
        case .openParentDirectory:
            openParent()
        case .openUnderCursor:
            openCurrentEntry()
        case .findFiles:
            presentFilePicker()
        case .liveGrep:
            presentGrepPicker()
        case .command(let name):
            message = "No mapping for \(name)"
        }
    }

    func save() {
        if isDirectory {
            guard let snap = directorySnapshot else { return }
            let ops = DirectoryListing.plan(
                original: snap,
                editedText: engine.text,
                incomingMoves: fsClipboard
            )
            if ops.isEmpty {
                engine.markSaved()
                modified = false
                message = "No filesystem changes"
                return
            }
            pendingOps = ops
            showConfirm = true
            return
        }
        writeFile()
    }

    func applyPendingOps() {
        for op in pendingOps {
            do {
                try apply(op)
            } catch {
                message = error.localizedDescription
                return
            }
        }
        fsClipboard.removeAll()
        pendingOps = []
        showConfirm = false
        if let url = fileURL, isDirectory {
            openDirectory(url)
        }
        engine.markSaved()
        modified = false
        message = "Applied"
    }

    func writeFile() {
        guard let url = fileURL else {
            saveAs()
            return
        }
        var text = engine.text
        if usesCRLF {
            text = text.replacingOccurrences(of: "\n", with: "\r\n")
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            engine.markSaved()
            modified = false
            lsp?.didSave(uri: url.absoluteString, text: engine.text)
            message = "Saved"
        } catch {
            message = error.localizedDescription
        }
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "untitled.md"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.fileURL = url
            self?.rootURL = url.deletingLastPathComponent()
            self?.title = url.lastPathComponent
            self?.writeFile()
        }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.open(url: url)
        }
    }

    func openParent() {
        if isDirectory {
            let parent = (fileURL ?? rootURL).deletingLastPathComponent()
            if parent.path != (fileURL ?? rootURL).path {
                openDirectory(parent)
            }
            return
        }
        if let url = fileURL {
            openDirectory(url.deletingLastPathComponent())
        } else {
            openDirectory(rootURL)
        }
    }

    func openCurrentEntry() {
        guard isDirectory, let snap = directorySnapshot else { return }
        let line = engine.lineTextUnderCursor()
        let parsed = ParsedDirLine(line)
        guard !parsed.name.isEmpty else { return }
        let dest = snap.directory.appendingPathComponent(parsed.name)
        open(url: dest)
    }

    func goToDefinition() {
        if let url = fileURL, let client = lsp, client.isRunning {
            let pos = LSPPosition.utf16(in: engine.text, characterOffset: engine.cursor)
            if let locs = try? client.definition(uri: url.absoluteString, position: pos), let first = locs.first, let dest = first.fileURL {
                open(url: dest)
                engine.moveCursor(to: LSPPosition.characterOffset(in: engine.text, position: first.range.start))
                return
            }
        }
        if let name = Wikilink.at(cursor: engine.cursor, in: engine.text) {
            jumpToFilename(name)
        }
    }

    func jumpToFilename(_ name: String) {
        let files = FileWalk.files(in: rootURL, extensions: [".md", ".markdown", ".txt"])
        let stem = (name as NSString).deletingPathExtension
        if let match = files.first(where: {
            $0.deletingPathExtension().lastPathComponent == stem
                || $0.lastPathComponent == name
                || $0.path.contains(name)
        }) {
            open(url: match)
        } else {
            message = "No file matching \(name)"
        }
    }

    func presentFilePicker() {
        let files = FileWalk.files(in: rootURL, ignore: IgnoreRules.load(from: rootURL))
        let items = files.map { url -> PickerItem in
            let rel = url.path.replacingOccurrences(of: rootURL.path + "/", with: "")
            let preview = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return PickerItem(title: rel, payload: url.path, preview: String(preview.prefix(800)))
        }
        pickerKind = .files
        picker = PickerEngine(source: items)
        message = "<leader>sf"
    }

    func presentGrepPicker() {
        let root = rootURL
        let ignore = IgnoreRules.load(from: root)
        pickerKind = .grep
        picker = PickerEngine(liveSearch: { query in
            guard !query.isEmpty else { return [] }
            return ContentSearch.search(root: root, query: query, ignore: ignore).map { hit in
                PickerItem(
                    title: "\(hit.path):\(hit.line)",
                    subtitle: hit.snippet,
                    payload: "\(root.appendingPathComponent(hit.path).path):\(hit.line)",
                    preview: hit.snippet
                )
            }
        })
        message = "<leader>sg"
    }

    func handlePicker(_ key: PickerKey) {
        guard let picker else { return }
        switch picker.handle(key) {
        case .none:
            objectWillChange.send()
        case .close:
            self.picker = nil
            pickerKind = nil
        case .confirm:
            if let item = picker.selected {
                openPickerPayload(item.payload)
            }
            self.picker = nil
            pickerKind = nil
        }
    }

    func openPickerPayload(_ payload: String) {
        let parts = payload.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count >= 2, let line = Int(parts.last!), parts.count >= 2 {
            let path = parts.dropLast().joined(separator: ":")
            open(url: URL(fileURLWithPath: path))
            jumpToLine(line)
            return
        }
        open(url: URL(fileURLWithPath: payload))
    }

    func jumpToLine(_ line: Int) {
        let target = max(0, line - 1)
        if target < engine.buffer.lineCount {
            engine.moveCursor(to: engine.buffer.lineStarts[target])
        }
        objectWillChange.send()
    }

    func toggleFocus() {
        focusMode.toggle()
    }

    func nsDiagnosticRanges() -> [(NSRange, Int)] {
        diagnostics.compactMap { diag in
            let start = LSPPosition.characterOffset(in: engine.text, position: diag.range.start)
            let end = LSPPosition.characterOffset(in: engine.text, position: diag.range.end)
            let loc = utf16(start)
            let max = utf16(end)
            return (NSRange(location: loc, length: max(0, max - loc)), diag.severity)
        }
    }

    private func utf16(_ characterOffset: Int) -> Int {
        let text = engine.text
        let i = text.index(text.startIndex, offsetBy: min(max(0, characterOffset), text.count))
        return i.utf16Offset(in: text)
    }

    private func captureDirectoryYank() {
        guard isDirectory, let snap = directorySnapshot else { return }
        let parsed = DirectoryListing.parse(engine.unnamedRegister.text)
        for line in parsed {
            if let entry = snap.entries.first(where: { $0.name == line.name }) {
                if !fsClipboard.contains(where: { $0.originalURL == entry.originalURL }) {
                    fsClipboard.append(entry)
                }
            }
        }
    }

    private func apply(_ op: FSOperation) throws {
        let fm = FileManager.default
        switch op {
        case .create(_, let name, let isDirectory):
            let dest = (fileURL ?? rootURL).appendingPathComponent(name)
            if isDirectory {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            } else {
                try Data().write(to: dest)
            }
        case .delete(let url):
            var trashed: NSURL?
            try fm.trashItem(at: url, resultingItemURL: &trashed)
        case .rename(let from, let to):
            if fm.fileExists(atPath: to.path) {
                throw NSError(domain: "Quill", code: 1, userInfo: [NSLocalizedDescriptionKey: "Already exists: \(to.lastPathComponent)"])
            }
            try fm.moveItem(at: from, to: to)
        }
    }

    private func startLSPIfNeeded() {
        lsp?.stop()
        lsp = nil
        guard let url = fileURL,
              let server = config.lsp.server(for: url) else { return }
        let client = LSPClient(config: server)
        let root = WorkspaceRoot.find(from: url, markers: server.rootMarkers.isEmpty ? [".git"] : server.rootMarkers)
        do {
            try client.start(root: root)
            client.onDiagnostics = { [weak self] _, diags in
                DispatchQueue.main.async { self?.diagnostics = diags }
            }
            lsp = client
            message = "LSP: \(server.name)"
        } catch {
            message = ""
        }
    }

    private func requestHover() {
        guard !isDirectory, let url = fileURL, let client = lsp, client.isRunning else {
            hoverText = nil
            return
        }
        let pos = LSPPosition.utf16(in: engine.text, characterOffset: engine.cursor)
        DispatchQueue.global(qos: .userInitiated).async {
            let hover = try? client.hover(uri: url.absoluteString, position: pos)
            DispatchQueue.main.async {
                self.hoverText = hover?.contents
            }
        }
    }

    private func updateWikilinkCompletion() {
        guard engine.mode == .insert,
              let prefix = Wikilink.prefixBeforeCursor(engine.text, cursor: engine.cursor) else {
            completions = []
            return
        }
        let files = FileWalk.files(in: rootURL, extensions: [".md", ".markdown"])
        let names = files.map { $0.deletingPathExtension().lastPathComponent }
        completions = Fuzzy.rank(query: prefix, candidates: Array(Set(names))).prefix(8).map(\.value)
    }

    func applyCompletion(_ name: String) {
        guard let prefix = Wikilink.prefixBeforeCursor(engine.text, cursor: engine.cursor) else { return }
        let start = engine.cursor - prefix.count
        engine.buffer.replace(start..<engine.cursor, with: name)
        engine.moveCursor(to: start + name.count)
        completions = []
        objectWillChange.send()
    }

    private func refreshStatus() {
        status = engine.mode.displayName
        modified = engine.isModified
        if engine.mode == .commandLine || engine.mode == .search {
            message = engine.commandLine
        }
        objectWillChange.send()
    }
}
