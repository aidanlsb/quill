import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import QuillFS
import QuillLSP
import QuillMarkdown
import QuillSearch
import QuillVim
import QuillWorkspace

@MainActor
@Observable
final class AppModel {
    let engine = Engine(clipboard: PasteboardClipboard())
    let config: QuillConfig

    var title = "Untitled"
    var status = "NORMAL"
    var message = ""
    var modified = false
    var focusMode = false
    var theme = QuillTheme.current()
    var isDirectory = false
    var hoverText: String?
    var picker: PickerEngine?
    var pickerKind: PickerKind?
    var pickerTick = 0
    var pendingOps: [FSOperation] = []
    var showConfirm = false
    var confirmWarning = ""
    var completions: [String] = []
    var diagnostics: [Diagnostic] = []
    var showUnsaved = false

    enum PickerKind { case files, grep }
    enum PendingNavigation {
        case open(URL)
        case newFile
        case close(NSWindow)
        case terminate
    }

    private(set) var fileURL: URL?
    private(set) var rootURL: URL
    private(set) var directorySnapshot: DirectorySnapshot?
    private var ending: LineEnding = .lf
    private var loadedAt: Date?
    private var confirmOverwrite = false
    private var docVersion = 1
    private var sync = DocumentSync()
    private var fsClipboard: [DirEntry] = []
    private var appearanceObserver: NSKeyValueObservation?
    private let servers = LanguageServerManager()
    private let searchSession = SearchSession()
    private let fileIndex = FileIndex()
    private let fileTypes = FileTypeRegistry()
    private var grepTask: Task<Void, Never>?
    private var hoverGeneration = 0
    private var lspURI: String?
    var pendingNavigation: PendingNavigation?
    var themeIdentity = 0

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        rootURL = home
        let loaded = QuillConfig.loadReporting()
        config = loaded.config
        if let error = loaded.error { message = error }
        config.apply(to: engine)
        appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.theme = QuillTheme.current(columnCharacters: self.config.columnWidth)
                self.themeIdentity += 1
            }
        }
        theme = QuillTheme.current(columnCharacters: config.columnWidth)
    }

    var modeName: String { engine.mode.displayName }

    func open(url: URL) {
        switch NavigationGuard.decide(isModified: engine.isModified, force: false) {
        case .prompt(let text):
            message = text
            pendingNavigation = .open(url)
            showUnsaved = true
            return
        case .allow:
            break
        }
        performOpen(url)
    }

    func openDirectory(_ url: URL) {
        switch NavigationGuard.decide(isModified: engine.isModified && isDirectory, force: false) {
        case .prompt(let text):
            message = text
            pendingNavigation = .open(url)
            showUnsaved = true
            return
        case .allow:
            break
        }
        loadDirectory(url)
    }

    func newUntitled() {
        switch NavigationGuard.decide(isModified: engine.isModified, force: false) {
        case .prompt(let text):
            message = text
            pendingNavigation = .newFile
            showUnsaved = true
            return
        case .allow:
            performNew()
        }
    }

    func discardAndContinue() {
        engine.markSaved()
        modified = false
        showUnsaved = false
        let pending = pendingNavigation
        pendingNavigation = nil
        switch pending {
        case .open(let url):
            performOpen(url)
        case .newFile:
            performNew()
        case .close(let window):
            window.close()
        case .terminate:
            NSApp.reply(toApplicationShouldTerminate: true)
        case nil:
            break
        }
    }

    func cancelNavigation() {
        let pending = pendingNavigation
        showUnsaved = false
        pendingNavigation = nil
        if case .terminate = pending {
            NSApp.reply(toApplicationShouldTerminate: false)
        }
    }

    func saveAndContinue() {
        save()
        if !engine.isModified {
            discardAndContinue()
        }
    }

    func requestClose(_ window: NSWindow) -> Bool {
        switch NavigationGuard.decide(isModified: engine.isModified, force: false) {
        case .allow:
            return true
        case .prompt(let text):
            message = text
            pendingNavigation = .close(window)
            showUnsaved = true
            return false
        }
    }

    func requestTerminate() -> NSApplication.TerminateReply {
        switch NavigationGuard.decide(isModified: engine.isModified, force: false) {
        case .allow:
            return .terminateNow
        case .prompt(let text):
            message = text
            pendingNavigation = .terminate
            showUnsaved = true
            return .terminateLater
        }
    }

    func handleEngineResult(_ result: EngineResult) {
        modified = engine.isModified
        status = engine.mode.displayName
        if !engine.statusMessage.isEmpty { message = engine.statusMessage }
        if engine.mode == .commandLine || engine.mode == .search { message = engine.commandLine }
        if result.didChangeText, !isDirectory {
            sync.apply(edits: result.edits.map { ($0.range, $0.replacement) })
            pushLSPChange()
            updateWikilinkCompletion()
        }
        for action in result.actions { perform(action) }
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
            if !engine.isModified { NSApp.keyWindow?.close() }
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
            if name == "split" || name == "vsplit" {
                message = "Split the window from the view layer once a second EditorWindow is attached"
            } else if name.hasPrefix("edit:") {
                let path = String(name.dropFirst("edit:".count))
                open(url: URL(fileURLWithPath: path))
            } else {
                message = "No mapping for \(name)"
            }
        }
    }

    func save() {
        if isDirectory {
            guard let snap = directorySnapshot else { return }
            let ops = DirectoryListing.plan(original: snap, lines: listingLines())
            if ops.isEmpty {
                engine.markSaved()
                modified = false
                message = "No filesystem changes"
                return
            }
            pendingOps = ops
            confirmWarning = DirectoryListing.mixesDeletesAndCreates(ops)
                ? "This save both deletes and creates files. Check the names before applying."
                : ""
            showConfirm = true
            return
        }
        writeFile()
    }

    func applyPendingOps() {
        let fs = TrashFileSystem()
        do {
            try FSExecutor.apply(pendingOps, fs: fs)
        } catch let error as FSExecutionError {
            message = "\(error.failed): \(error.message)"
            return
        } catch {
            message = error.localizedDescription
            return
        }
        fsClipboard.removeAll()
        pendingOps = []
        showConfirm = false
        if let url = fileURL, isDirectory { loadDirectory(url) }
        engine.markSaved()
        modified = false
        message = "Applied"
    }

    func writeFile() {
        guard let url = fileURL else {
            saveAs()
            return
        }
        if let loadedAt, let current = modificationDate(url),
           ExternalChange.conflicts(loaded: loadedAt, current: current), !confirmOverwrite {
            confirmOverwrite = true
            message = "File changed on disk. Save again to overwrite."
            return
        }
        let data = TextCodec.encode(engine.text, ending: ending)
        let bytes = data
        Task {
            do {
                try await Task.detached {
                    try bytes.write(to: url, options: .atomic)
                }.value
                self.engine.markSaved()
                self.modified = false
                self.loadedAt = self.modificationDate(url)
                self.confirmOverwrite = false
                self.lspDidSave(url)
                self.message = "Saved"
                if self.pendingNavigation != nil { self.discardAndContinue() }
            } catch {
                self.message = error.localizedDescription
            }
        }
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "untitled.md"
        panel.begin { [weak self] response in
            Task { @MainActor [weak self] in
                guard let self, response == .OK, let url = panel.url else { return }
                self.fileURL = url
                self.rootURL = url.deletingLastPathComponent()
                self.title = url.lastPathComponent
                self.writeFile()
            }
        }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            Task { @MainActor [weak self] in
                guard let self, response == .OK, let url = panel.url else { return }
                self.open(url: url)
            }
        }
    }

    func openParent() {
        let base = fileURL ?? rootURL
        if isDirectory {
            let parent = base.deletingLastPathComponent()
            if parent.path != base.path { openDirectory(parent) }
            return
        }
        openDirectory(base.deletingLastPathComponent())
    }

    func openCurrentEntry() {
        guard isDirectory, let snap = directorySnapshot else { return }
        let line = engine.lineTextUnderCursor()
        let parsed = ParsedDirLine(line)
        guard !parsed.name.isEmpty else { return }
        open(url: snap.directory.appendingPathComponent(parsed.name))
    }

    func goToDefinition() {
        if let url = fileURL, lspURI != nil {
            let pos = LSPPosition.position(utf16Offset: engine.cursor, in: engine.text)
            let uri = url.absoluteString
            Task {
                let clients = await serversForCurrentFile()
                for client in clients where client.capabilities.definitionProvider || client.isRunning {
                    if let locs = try? await client.definition(uri: uri, position: pos), let first = locs.first, let dest = first.fileURL {
                        self.open(url: dest)
                        let offset = LSPPosition.utf16Offset(in: self.engine.text, position: first.range.start)
                        self.engine.moveCursor(to: offset)
                        return
                    }
                }
                self.followWikilink()
            }
            return
        }
        followWikilink()
    }

    func presentFilePicker() {
        let root = rootURL
        Task {
            await fileIndex.rebuild(root: root, ignore: IgnoreRules.load(from: root))
            let paths = await fileIndex.relativePaths()
            let items = paths.map { path in
                PickerItem(title: path, payload: root.appendingPathComponent(path).path, preview: "")
            }
            let picker = PickerEngine(source: items)
            self.pickerKind = .files
            self.picker = picker
            self.message = "<leader>sf"
            self.loadPreviewForSelection()
        }
    }

    func presentGrepPicker() {
        let picker = PickerEngine()
        picker.onQueryChange = { [weak self] query in
            self?.scheduleGrep(query)
        }
        pickerKind = .grep
        self.picker = picker
        message = "<leader>sg"
    }

    func handlePicker(_ key: PickerKey) {
        guard let picker else { return }
        switch picker.handle(key) {
        case .none:
            pickerTick += 1
            loadPreviewForSelection()
        case .close:
            self.picker = nil
            pickerKind = nil
        case .confirm:
            if let item = picker.selected { openPickerPayload(item.payload) }
            self.picker = nil
            pickerKind = nil
        }
    }

    func openPickerPayload(_ payload: String) {
        let parts = payload.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if parts.count >= 2, let line = Int(parts.last ?? "") {
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
        pickerTick += 1
    }

    func toggleFocus() { focusMode.toggle() }

    func nsDiagnosticRanges() -> [(NSRange, Int)] {
        diagnostics.map { diag in
            let start = LSPPosition.utf16Offset(in: engine.text, position: diag.range.start)
            let end = LSPPosition.utf16Offset(in: engine.text, position: diag.range.end)
            return (NSRange(location: start, length: max(0, end - start)), diag.severity)
        }
    }

    func applyCompletion(_ name: String) {
        guard let prefix = WikilinkQuery.prefix(before: engine.cursor, in: engine.text) else { return }
        let start = engine.cursor - prefix.utf16.count
        _ = engine.applyHostEdit(replacing: start..<engine.cursor, with: name)
        completions = []
        modified = engine.isModified
    }

    private func performOpen(_ url: URL) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            loadDirectory(url)
            rootURL = url
            return
        }
        Task {
            let result = await Task.detached { () -> Result<TextCodec.Decoded, Error> in
                do {
                    let data = try Data(contentsOf: url)
                    return .success(try TextCodec.decode(data))
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case .failure(let error):
                self.message = error.localizedDescription
            case .success(let decoded):
                self.installFile(decoded, url: url)
            }
        }
    }

    private func installFile(_ decoded: TextCodec.Decoded, url: URL) {
        engine.load(text: decoded.text)
        ending = decoded.ending
        fileURL = url
        rootURL = url.deletingLastPathComponent()
        isDirectory = false
        engine.openOnEnter = false
        directorySnapshot = nil
        title = url.lastPathComponent
        modified = false
        loadedAt = modificationDate(url)
        confirmOverwrite = false
        sync = DocumentSync(text: decoded.text, version: 1)
        docVersion = 1
        startLSP(for: url, text: decoded.text)
        refreshStatus()
    }

    private func performNew() {
        engine.load(text: "")
        fileURL = nil
        isDirectory = false
        engine.openOnEnter = false
        title = "Untitled"
        modified = false
        sync = DocumentSync()
        refreshStatus()
    }

    private func loadDirectory(_ url: URL) {
        do {
            let snap = try DirectoryListing.snapshot(of: url)
            directorySnapshot = snap
            engine.load(text: DirectoryListing.render(snap))
            for (index, entry) in snap.entries.enumerated() {
                engine.setDirectoryAnchor(
                    line: index,
                    id: entry.entryID ?? DirectoryListing.stableID(for: entry.originalURL?.path ?? entry.name),
                    sourcePath: entry.originalURL?.path ?? url.appendingPathComponent(entry.name).path,
                    isDirectory: entry.isDirectory
                )
            }
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

    private func listingLines() -> [ListingLine] {
        var lines: [ListingLine] = []
        var offset = 0
        let text = engine.text
        let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
        for raw in parts {
            let line = String(raw)
            let parsed = ParsedDirLine(line)
            let end = offset + line.utf16.count
            let anchor = engine.buffer.anchors(in: offset..<(end + 1)).first { anchor in
                if case .directoryEntry = anchor.kind { return true }
                return false
            }
            if !parsed.name.isEmpty {
                if let anchor, case .directoryEntry(let path, _, let transfer) = anchor.kind {
                    let kind: LineTransfer
                    switch transfer {
                    case .identity: kind = .identity
                    case .move: kind = .move
                    case .copy: kind = .copy
                    }
                    lines.append(ListingLine(
                        name: parsed.name,
                        isDirectory: parsed.isDirectory,
                        entryID: anchor.id.raw,
                        sourcePath: path,
                        transfer: kind
                    ))
                } else {
                    lines.append(ListingLine(name: parsed.name, isDirectory: parsed.isDirectory))
                }
            }
            offset = end + 1
        }
        return lines
    }

    private func scheduleGrep(_ query: String) {
        grepTask?.cancel()
        let root = rootURL
        grepTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 40_000_000)
            if Task.isCancelled { return }
            let hits = await searchSession.search(root: root, query: query, ignore: IgnoreRules.load(from: root))
            let items = hits.map { hit -> PickerItem in
                let absolute = hit.path.hasPrefix("/") ? hit.path : root.appendingPathComponent(hit.path).path
                return PickerItem(
                    title: "\(hit.path):\(hit.line)",
                    subtitle: hit.snippet,
                    payload: "\(absolute):\(hit.line)",
                    preview: ""
                )
            }
            self.picker?.replaceItems(items)
            self.pickerTick += 1
        }
    }

    private func loadPreviewForSelection() {
        guard pickerKind == .files, let payload = picker?.selected?.payload, picker?.selected?.preview.isEmpty == true else { return }
        let url = URL(fileURLWithPath: payload)
        Task {
            let text = await Task.detached { () -> String in
                (try? String(contentsOf: url, encoding: .utf8)).map { String($0.prefix(800)) } ?? ""
            }.value
            self.picker?.updatePreview(payload: payload, text: text)
            self.pickerTick += 1
        }
    }

    private func followWikilink() {
        if let name = WikilinkQuery.at(cursor: engine.cursor, in: engine.text) {
            jumpToFilename(name)
        }
    }

    private func jumpToFilename(_ name: String) {
        Task {
            if await fileIndex.root?.path != rootURL.path {
                await fileIndex.rebuild(root: rootURL, ignore: IgnoreRules.load(from: rootURL))
            }
            let files = await fileIndex.files
            let stem = (name as NSString).deletingPathExtension
            if let match = files.first(where: {
                $0.deletingPathExtension().lastPathComponent == stem || $0.lastPathComponent == name
            }) {
                self.open(url: match)
            } else {
                self.message = "No file matching \(name)"
            }
        }
    }

    private func updateWikilinkCompletion() {
        guard engine.mode == .insert,
              let prefix = WikilinkQuery.prefix(before: engine.cursor, in: engine.text) else {
            completions = []
            return
        }
        let root = rootURL
        Task {
            if await fileIndex.root?.path != root.path {
                await fileIndex.rebuild(root: root, ignore: IgnoreRules())
            }
            let names = await fileIndex.files.map { $0.deletingPathExtension().lastPathComponent }
            self.completions = Fuzzy.rank(query: prefix, candidates: Array(Set(names))).prefix(8).map(\.value)
        }
    }

    private func startLSP(for url: URL, text: String) {
        let language = fileTypes.languageId(for: url)
        let uri = url.absoluteString
        lspURI = uri
        Task {
            let configs = config.lsp.servers(for: url)
            guard let server = configs.first else { return }
            let root = WorkspaceRoot.find(from: url, markers: server.rootMarkers.isEmpty ? [".git"] : server.rootMarkers)
            do {
                let client = try await servers.connection(config: server, root: root)
                let key = LanguageServerManager.ConnectionKey(name: server.name, root: root.path)
                let already = await servers.isOpen(key: key, uri: uri)
                client.onDiagnostics = { [weak self] diagURI, diags in
                    Task { @MainActor [weak self] in
                        guard let self, diagURI == self.fileURL?.absoluteString else { return }
                        self.diagnostics = diags
                    }
                }
                if !already {
                    client.didOpen(uri: uri, languageId: language, version: docVersion, text: text)
                    await servers.trackOpen(key: key, uri: uri)
                }
                self.message = "LSP: \(server.name)"
            } catch {
                self.message = ""
            }
        }
    }

    private func pushLSPChange() {
        guard let url = fileURL else { return }
        let uri = url.absoluteString
        Task {
            let clients = await serversForCurrentFile()
            let flushed = sync.flush(incremental: true)
            let full = LSPContentChange(text: sync.text)
            for client in clients {
                let changes = client.capabilities.incrementalSync ? flushed.changes : [full]
                if changes.isEmpty { continue }
                client.didChange(uri: uri, version: flushed.version, changes: changes)
            }
        }
    }

    private func lspDidSave(_ url: URL) {
        Task {
            let clients = await serversForCurrentFile()
            for client in clients {
                client.didSave(uri: url.absoluteString, text: engine.text)
            }
        }
    }

    private func serversForCurrentFile() async -> [LSPClient] {
        guard let url = fileURL else { return [] }
        var found: [LSPClient] = []
        for server in config.lsp.servers(for: url) {
            let root = WorkspaceRoot.find(from: url, markers: server.rootMarkers.isEmpty ? [".git"] : server.rootMarkers)
            let key = LanguageServerManager.ConnectionKey(name: server.name, root: root.path)
            if let client = await servers.client(key) { found.append(client) }
        }
        return found
    }

    private func requestHover() {
        guard !isDirectory, let url = fileURL else {
            hoverText = nil
            return
        }
        hoverGeneration += 1
        let generation = hoverGeneration
        let pos = LSPPosition.position(utf16Offset: engine.cursor, in: engine.text)
        let uri = url.absoluteString
        Task {
            let clients = await serversForCurrentFile()
            guard let client = clients.first, client.isRunning else { return }
            let hover = try? await client.hover(uri: uri, position: pos)
            if generation == self.hoverGeneration {
                self.hoverText = hover?.contents
            }
        }
    }

    private func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func refreshStatus() {
        status = engine.mode.displayName
        modified = engine.isModified
        if engine.mode == .commandLine || engine.mode == .search { message = engine.commandLine }
    }
}

struct TrashFileSystem: FileSystem {
    private let fm = FileManager.default

    func exists(_ path: String) -> Bool { fm.fileExists(atPath: path) }

    func createDirectory(_ path: String) throws {
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    func writeFile(_ path: String, data: Data) throws {
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    func remove(_ path: String) throws {
        var trashed: NSURL?
        try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &trashed)
    }

    func move(from: String, to: String) throws {
        try fm.moveItem(atPath: from, toPath: to)
    }

    func copy(from: String, to: String) throws {
        try fm.copyItem(atPath: from, toPath: to)
    }
}
