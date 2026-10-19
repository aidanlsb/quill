import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import QuillFS
import QuillLSP
import QuillMarkdown
import QuillSearch
import QuillText
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
    var picker: PickerEngine?
    var pickerKind: PickerKind?
    var pickerTick = 0
    /// Editor mode and cursor to restore when the command palette closes.
    var paletteMode: Mode?
    var paletteCursor: Int?
    let commands = QuillSearch.CommandRegistry()
    var pendingOps: [FSOperation] = []
    var showConfirm = false
    var confirmWarning = ""
    var completions: [String] = []
    /// `-1` until Ctrl-n/p or an arrow chooses a row. The first Ctrl-n selects the first match.
    var completionIndex = -1
    var diagnostics: [Diagnostic] = [] {
        didSet { rebuildDiagnosticRanges() }
    }
    /// UTF-16 ranges computed once when diagnostics arrive.
    var diagnosticRanges: [(NSRange, Int)] = []
    var showUnsaved = false
    /// The live text view. Nil in tests that drive the engine without a window.
    @ObservationIgnored
    weak var editor: VimTextView?

    enum PickerKind { case files, grep, references, codeAction, commands }
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
    private var appearanceObserver: NSKeyValueObservation?
    private let servers = LanguageServerManager()
    private let searchSession = SearchSession()
    private let fileIndex = FileIndex()
    private let fileTypes = FileTypeRegistry()
    private var grepTask: Task<Void, Never>?
    private var hoverGeneration = 0
    private var lsp: LSPDocumentLink?
    private var completionQuery: String?
    private var completionGeneration = 0
    private var pendingJumps: [String: LaunchTarget] = [:]
    private var codeActions: [CodeAction] = []
    var pendingNavigation: PendingNavigation?
    var themeIdentity = 0
    var themeChoice: ThemeChoice = .system
    /// Session override of `config.images`. The command palette toggles this.
    var showImages = true
    /// Atomic write of one snapshot. Tests pause this so an edit can land between
    /// the captured stamp and `markSaved(stamp:)`.
    var diskWrite: @Sendable (Data, URL) async throws -> Void = { bytes, url in
        try await Task.detached {
            try bytes.write(to: url, options: .atomic)
        }.value
    }
    /// How many times `file.close` ran. Tests observe `:wq` when no key window exists.
    private(set) var closeRequests = 0

    func recordCloseRequest() {
        closeRequests += 1
    }

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        rootURL = home
        let loaded = QuillConfig.loadReporting()
        config = loaded.config
        if let error = loaded.error { message = error }
        showImages = config.images
        themeChoice = ThemeChoice.resolved(
            config: config.theme,
            remembered: ThemeMemory.load(from: ThemeMemory.url(home: home))
        )
        appearanceObserver = NSApplication.shared.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.themeChoice == .system else { return }
                self.applyTheme(self.themeChoice, remember: false)
            }
        }
        theme = makeTheme(themeChoice)
        installCommands()
        config.apply(to: self)
    }

    func setTheme(_ choice: ThemeChoice) {
        applyTheme(choice, remember: true)
    }

    func toggleImages() {
        showImages.toggle()
        message = showImages ? "images on" : "images off"
    }

    func toggleTheme() {
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        let systemDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        applyTheme(themeChoice.toggled(systemIsDark: systemDark), remember: true)
    }

    private func applyTheme(_ choice: ThemeChoice, remember: Bool) {
        themeChoice = choice
        theme = makeTheme(choice)
        themeIdentity += 1
        guard remember else { return }
        message = "theme \(choice.rawValue)"
        let url = ThemeMemory.url(home: FileManager.default.homeDirectoryForCurrentUser)
        do {
            try ThemeMemory.save(choice, to: url)
        } catch {
            message = "theme \(choice.rawValue) (\(error.localizedDescription))"
        }
    }

    private func makeTheme(_ choice: ThemeChoice) -> QuillTheme {
        QuillTheme.current(
            fontFamily: config.font,
            fontSize: config.fontSize,
            columnCharacters: config.columnWidth,
            scheme: choice
        )
    }

    func open(url: URL) {
        if let target = LaunchRequest.target(from: url) {
            openTarget(target)
            return
        }
        openTarget(LaunchTarget(path: url.path))
    }

    /// Last parsed launch argument wins. `open` delivers `quill://` URLs separately.
    func consumeLaunchArguments(_ arguments: [String]) {
        guard let target = LaunchRequest.parse(arguments).last else { return }
        openTarget(target)
    }

    func openTarget(_ target: LaunchTarget) {
        let path = LaunchRequest.standardized(target.path)
        if LaunchRequest.sameFile(open: fileURL?.path, isDirectory: isDirectory, target: path) {
            jump(to: target)
            return
        }
        if target.line != nil {
            pendingJumps[path] = target
        } else {
            pendingJumps.removeValue(forKey: path)
        }
        let url = URL(fileURLWithPath: path)
        switch NavigationGuard.decide(isModified: engine.isModified, force: false) {
        case .prompt(let text):
            message = text
            pendingNavigation = .open(url)
            showUnsaved = true
            return
        case .allow:
            performOpen(url)
        }
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
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        case nil:
            break
        }
    }

    func cancelNavigation() {
        let pending = pendingNavigation
        showUnsaved = false
        pendingNavigation = nil
        if case .open(let url) = pending {
            pendingJumps.removeValue(forKey: url.standardizedFileURL.path)
        }
        if case .terminate = pending {
            NSApplication.shared.reply(toApplicationShouldTerminate: false)
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

    func afterEdit(_ result: EngineResult) {
        setIfChanged(\.modified, engine.isModified)
        setIfChanged(\.status, engine.mode.displayName)
        if !engine.statusMessage.isEmpty {
            setIfChanged(\.message, engine.statusMessage)
        }
        if engine.mode == .commandLine || engine.mode == .search {
            setIfChanged(\.message, engine.commandLine)
        }
        if result.didChangeText, !isDirectory {
            lsp?.didEdit(result.edits)
            if engine.mode == .insert {
                updateWikilinkCompletion()
            } else if !completions.isEmpty {
                clearCompletions()
            }
        }
        for action in result.actions { perform(action) }
        refreshStatus()
    }

    /// Host edit: the text view applies it, then `afterEdit` runs. Without a view, only the model updates.
    private func apply(_ result: EngineResult) {
        if let editor {
            editor.applyResult(result)
        } else {
            afterEdit(result)
        }
    }

    private func setIfChanged<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppModel, T>, _ value: T) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }

    var hasLanguageServer: Bool { lsp != nil }

    /// Tests install a scripted client without spawning a server process.
    func adoptLanguageLink(_ link: LSPDocumentLink) {
        lsp?.close()
        lsp = link
    }

    func perform(_ action: HostAction) {
        switch action {
        case .command(let id):
            if !runCommand(id) { message = "No command \(id)" }
        case .ex(let call):
            guard let id = commands.command(forEx: call.name) else {
                message = "Not an editor command: \(call.name)"
                NSSound.beep()
                return
            }
            commands.run(
                id: id,
                args: CommandArgs(text: call.args, lines: call.lines, bang: call.bang)
            )
        }
    }

    func close(bang: Bool) {
        if !bang && engine.isModified {
            message = "No write since last change"
            NSSound.beep()
            return
        }
        if bang {
            engine.markSaved()
            modified = false
        }
        recordCloseRequest()
        NSApplication.shared.keyWindow?.close()
    }

    func edit(_ args: CommandArgs) {
        if !args.text.isEmpty {
            if engine.isModified && !args.bang {
                message = "No write since last change"
                NSSound.beep()
                return
            }
            open(url: resolvePath(args.text))
            return
        }
        guard let url = fileURL else {
            message = "No file"
            NSSound.beep()
            return
        }
        if engine.isModified && !args.bang {
            message = "No write since last change"
            NSSound.beep()
            return
        }
        if isDirectory {
            loadDirectory(url)
            message = "Reloaded"
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
            guard self.fileURL == url else { return }
            switch result {
            case .failure(let error):
                self.message = error.localizedDescription
            case .success(let decoded):
                self.installFile(decoded, url: url)
                self.message = "Reloaded"
            }
        }
    }

    func save(toPath path: String) {
        let url = resolvePath(path)
        if fileURL == nil {
            fileURL = url
            rootURL = url.deletingLastPathComponent()
            title = url.lastPathComponent
            isDirectory = false
            ending = .lf
            writeFile()
            return
        }
        if fileURL?.standardizedFileURL.path == url.standardizedFileURL.path {
            writeFile()
            return
        }
        let data = TextCodec.encode(engine.text, ending: ending)
        let write = diskWrite
        Task {
            do {
                try await write(data, url)
                self.message = "Saved"
            } catch {
                self.message = error.localizedDescription
            }
        }
    }

    private func resolvePath(_ text: String) -> URL {
        if text.hasPrefix("/") {
            return URL(fileURLWithPath: text)
        }
        return rootURL.appendingPathComponent(text)
    }

    func formatTables(startLine: Int?, endLine: Int?, quiet: Bool) {
        guard !isDirectory else { return }
        let scope: TableScope
        if let startLine, let endLine {
            scope = .lines(min(startLine, endLine)...max(startLine, endLine))
        } else {
            scope = .cursor
        }
        let plan = MarkdownTables.plan(in: engine.text, scope: scope, cursor: engine.cursor)
        guard plan.matched else {
            if !quiet { message = "Not a table" }
            return
        }
        guard !plan.rewrites.isEmpty else { return }
        let edits = plan.rewrites.map { TextEdit(range: $0.range, replacement: $0.replacement) }
        let result = engine.applyHostEdits(edits, cursor: plan.cursor)
        apply(result)
    }

    func save(then completion: (@MainActor () -> Void)? = nil) {
        if isDirectory {
            guard let snap = directorySnapshot else { return }
            let ops = DirectoryListing.plan(original: snap, lines: listingLines())
            if ops.isEmpty {
                engine.markSaved()
                modified = false
                message = "No filesystem changes"
                if !engine.isModified { completion?() }
                return
            }
            pendingOps = ops
            confirmWarning = DirectoryListing.mixesDeletesAndCreates(ops)
                ? "This save both deletes and creates files. Check the names before applying."
                : ""
            showConfirm = true
            return
        }
        writeFile(then: completion)
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
        pendingOps = []
        showConfirm = false
        if let url = fileURL, isDirectory { loadDirectory(url) }
        engine.markSaved()
        modified = false
        message = "Applied"
    }

    func writeFile(then completion: (@MainActor () -> Void)? = nil) {
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
        // Stamp and bytes are this snapshot. A later edit keeps the buffer dirty,
        // and a buffer replaced while the write runs is left alone.
        let stamp = engine.changeStamp
        let savedURL = url
        let data = TextCodec.encode(engine.text, ending: ending)
        let write = diskWrite
        Task {
            do {
                try await write(data, savedURL)
                guard self.fileURL == savedURL else { return }
                self.engine.markSaved(stamp: stamp)
                self.modified = self.engine.isModified
                self.loadedAt = self.modificationDate(savedURL)
                self.confirmOverwrite = false
                self.lspDidSave(savedURL)
                self.message = "Saved"
                guard !self.engine.isModified else { return }
                if self.pendingNavigation != nil {
                    self.discardAndContinue()
                } else {
                    completion?()
                }
            } catch {
                guard self.fileURL == savedURL else { return }
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
        guard let url = fileURL, let link = lsp else {
            followWikilink()
            return
        }
        let pos = LSPPosition(engine.buffer.position(of: engine.cursor))
        let uri = url.absoluteString
        Task {
            let clients = link.requestClients()
            for client in clients where client.capabilities.definitionProvider || client.isRunning {
                if let locs = try? await client.definition(uri: uri, position: pos), let first = locs.first, let dest = first.fileURL {
                    self.openTarget(LaunchTarget(
                        path: dest.path,
                        line: first.range.start.line + 1,
                        column: first.range.start.character + 1,
                        columnUnit: .utf16
                    ))
                    return
                }
            }
            self.followWikilink()
        }
    }

    func presentFilePicker() {
        let root = rootURL
        Task {
            let ignore = await IgnoreCache.shared.rules(for: root)
            await fileIndex.rebuild(root: root, ignore: ignore)
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
        if pickerKind == .commands, key == .escape {
            dismissCommandPalette(restore: true)
            return
        }
        switch picker.handle(key) {
        case .none:
            pickerTick += 1
            if pickerKind != .commands { loadPreviewForSelection() }
        case .close:
            if pickerKind == .commands {
                dismissCommandPalette(restore: true)
            } else {
                self.picker = nil
                pickerKind = nil
            }
        case .confirm:
            if pickerKind == .commands {
                let id = picker.selected?.payload
                dismissCommandPalette(restore: true)
                if let id, !runCommand(id) { message = "Unavailable" }
                return
            }
            let kind = pickerKind
            let item = picker.selected
            self.picker = nil
            pickerKind = nil
            guard let item else { break }
            if kind == .codeAction, let index = Int(item.payload), codeActions.indices.contains(index) {
                let action = codeActions[index]
                codeActions = []
                applyCodeAction(action)
            } else {
                codeActions = []
                openPickerPayload(item.payload, columnUnit: kind == .references ? .utf16 : .character)
            }
        }
    }

    func openPickerPayload(_ payload: String, columnUnit: LaunchTarget.ColumnUnit = .character) {
        let split = LaunchRequest.splitLocation(payload)
        openTarget(LaunchTarget(path: split.path, line: split.line, column: split.column, columnUnit: columnUnit))
    }

    private func jump(to target: LaunchTarget) {
        guard let line = target.line else { return }
        jumpToLine(line, column: target.column, unit: target.columnUnit)
    }

    /// `line` and `column` are 1-based; a line past the end goes to the last, as `vim +N` does.
    /// A character column lands on that grapheme whatever its UTF-16 width; a UTF-16
    /// column (from a language server) snaps to the grapheme holding that unit.
    func jumpToLine(_ line: Int, column: Int? = nil, unit: LaunchTarget.ColumnUnit = .character) {
        let index = min(max(0, line - 1), engine.buffer.lastLine)
        let col = max(1, column ?? 1) - 1
        let offset: Int
        switch unit {
        case .character:
            offset = engine.buffer.offset(line: index, graphemeColumn: col)
        case .utf16:
            offset = engine.buffer.offset(of: TextPosition(line: index, utf16Column: col))
        }
        apply(engine.moveCursor(to: offset))
        pickerTick += 1
    }

    func findReferences() {
        guard let url = fileURL, !isDirectory else {
            message = "No language server"
            return
        }
        let position = LSPPosition(engine.buffer.position(of: engine.cursor))
        let uri = url.absoluteString
        let text = engine.text
        guard let link = lsp else {
            message = "No language server"
            return
        }
        Task {
            let clients = link.requestClients()
            guard let client = clients.first(where: \.isRunning) else {
                self.message = "No language server"
                return
            }
            do {
                let locations = try await client.references(uri: uri, position: position)
                if locations.isEmpty {
                    self.message = "No references"
                    return
                }
                let items = locations.map { location -> PickerItem in
                    let line = location.range.start.line + 1
                    let column = location.range.start.character + 1
                    let path = location.fileURL?.path ?? location.uri
                    let name = location.fileURL?.lastPathComponent ?? location.uri
                    return PickerItem(
                        title: "\(name):\(line)",
                        subtitle: path,
                        payload: "\(path):\(line):\(column)",
                        preview: self.referencePreview(location, currentURI: uri, text: text)
                    )
                }
                self.codeActions = []
                self.pickerKind = .references
                self.picker = PickerEngine(source: items)
                self.message = "gr"
            } catch {
                self.message = error.localizedDescription
            }
        }
    }

    func presentCodeActions() {
        guard let url = fileURL, !isDirectory else {
            message = "No language server"
            return
        }
        let range: LSPRange
        if let selection = engine.visualSelection {
            range = LSPRange(
                start: LSPPosition(engine.buffer.position(of: selection.lowerBound)),
                end: LSPPosition(engine.buffer.position(of: selection.upperBound))
            )
        } else {
            let position = LSPPosition(engine.buffer.position(of: engine.cursor))
            range = LSPRange(start: position, end: position)
        }
        let uri = url.absoluteString
        let context = diagnostics
        guard let link = lsp else {
            message = "No language server"
            return
        }
        Task {
            let clients = link.requestClients()
            guard let client = clients.first(where: \.isRunning) else {
                self.message = "No language server"
                return
            }
            do {
                let actions = try await client.codeAction(uri: uri, range: range, diagnostics: context)
                    .sorted { $0.isPreferred && !$1.isPreferred }
                if actions.isEmpty {
                    self.message = "No code actions"
                    return
                }
                self.codeActions = actions
                let items = actions.enumerated().map { index, action in
                    PickerItem(
                        title: action.title,
                        subtitle: action.kind ?? "",
                        payload: String(index),
                        preview: action.kind ?? action.title
                    )
                }
                self.pickerKind = .codeAction
                self.picker = PickerEngine(source: items)
                self.message = "<leader>ca"
            } catch {
                self.message = error.localizedDescription
            }
        }
    }

    func toggleFocus() { focusMode.toggle() }

    func showHover() {
        if let text = diagnosticMessage(at: engine.cursor) {
            setIfChanged(\.message, text)
            return
        }
        guard let link = lsp else {
            setIfChanged(\.message, "No info")
            return
        }
        hoverGeneration += 1
        let generation = hoverGeneration
        let position = LSPPosition(engine.buffer.position(of: engine.cursor))
        Task {
            let hover = await link.hover(at: position)
            guard generation == self.hoverGeneration else { return }
            let line = hover?.contents.split(whereSeparator: \.isNewline).first.map(String.init)
            let shown = (line?.isEmpty == false) ? line! : "No info"
            self.setIfChanged(\.message, shown)
        }
    }

    /// Insert-mode keys for the completion list. Esc returns false so the engine still leaves insert.
    func handleCompletionKey(_ event: KeyEvent) -> Bool {
        guard engine.mode == .insert, !completions.isEmpty else { return false }
        switch event.key {
        case .ctrl("n"), .down:
            completionIndex += 1
            if completionIndex >= completions.count { completionIndex = 0 }
            return true
        case .ctrl("p"), .up:
            completionIndex -= 1
            if completionIndex < 0 { completionIndex = completions.count - 1 }
            return true
        case .ctrl("y"), .tab:
            let index = min(max(completionIndex, 0), completions.count - 1)
            applyCompletion(completions[index])
            return true
        case .ctrl("e"):
            clearCompletions()
            return true
        case .escape:
            clearCompletions()
            return false
        default:
            return false
        }
    }

    func applyCompletion(_ name: String) {
        let cursor = engine.cursor
        let line = engine.buffer.line(engine.buffer.lineIndex(containing: cursor))
        let end = min(max(cursor, line.start), line.contentEnd)
        let fragment = engine.buffer.substring(line.start..<end)
        guard let prefix = WikilinkQuery.prefix(before: end - line.start, in: fragment) else { return }
        let start = end - prefix.utf16.count
        let result = engine.applyHostEdit(replacing: start..<end, with: name)
        apply(result)
        clearCompletions()
    }

    private func performOpen(_ url: URL) {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if exists, isDir.boolValue {
            loadDirectory(url)
            rootURL = url
            return
        }
        if !exists {
            if let decoded = try? TextCodec.decode(Data()) {
                installFile(decoded, url: url)
            }
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
        directorySnapshot = nil
        rebuildKeymap()
        title = url.lastPathComponent
        modified = false
        loadedAt = modificationDate(url)
        confirmOverwrite = false
        startLSP(for: url, text: decoded.text)
        applyPendingJump(for: url)
        editor?.reload()
        refreshStatus()
    }

    private func performNew() {
        engine.load(text: "")
        fileURL = nil
        isDirectory = false
        rebuildKeymap()
        title = "Untitled"
        modified = false
        stopLSP()
        editor?.reload()
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
            isDirectory = true
            rebuildKeymap()
            fileURL = url
            rootURL = url
            title = url.lastPathComponent + "/"
            modified = false
            stopLSP()
            applyPendingJump(for: url)
            editor?.reload()
            refreshStatus()
        } catch {
            message = error.localizedDescription
        }
    }

    private func listingLines() -> [ListingLine] {
        var lines: [ListingLine] = []
        for (line, anchor) in engine.buffer.directoryEntryLines() {
            let parsed = ParsedDirLine(line)
            if parsed.name.isEmpty { continue }
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
        return lines
    }

    private func scheduleGrep(_ query: String) {
        grepTask?.cancel()
        let root = rootURL
        grepTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 40_000_000)
            if Task.isCancelled { return }
            let ignore = await IgnoreCache.shared.rules(for: root)
            if Task.isCancelled { return }
            let hits = await searchSession.search(root: root, query: query, ignore: ignore)
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
                let ignore = await IgnoreCache.shared.rules(for: rootURL)
                await fileIndex.rebuild(root: rootURL, ignore: ignore)
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
        guard engine.mode == .insert else {
            clearCompletions()
            return
        }
        let cursor = engine.cursor
        let line = engine.buffer.line(engine.buffer.lineIndex(containing: cursor))
        let end = min(max(cursor, line.start), line.contentEnd)
        let fragment = engine.buffer.substring(line.start..<end)
        guard let prefix = WikilinkQuery.prefix(before: end - line.start, in: fragment) else {
            clearCompletions()
            return
        }
        if prefix == completionQuery { return }
        completionQuery = prefix
        completionGeneration += 1
        let generation = completionGeneration
        let root = rootURL
        Task {
            if await fileIndex.root?.path != root.path {
                await fileIndex.rebuild(root: root, ignore: IgnoreRules())
            }
            guard generation == self.completionGeneration else { return }
            let names = await fileIndex.files.map { $0.deletingPathExtension().lastPathComponent }
            let ranked = Fuzzy.rank(query: prefix, candidates: Array(Set(names))).prefix(8).map(\.value)
            guard generation == self.completionGeneration else { return }
            self.completions = ranked
            self.completionIndex = -1
        }
    }

    private func clearCompletions() {
        completionGeneration += 1
        completionQuery = nil
        completionIndex = -1
        if !completions.isEmpty { completions = [] }
    }

    private func startLSP(for url: URL, text: String) {
        stopLSP()
        let configs = config.lsp.servers(for: url)
        guard !configs.isEmpty else { return }
        let language = fileTypes.languageId(for: url)
        let uri = url.absoluteString
        let roots = configs.map { server in
            WorkspaceRoot.find(from: url, markers: server.rootMarkers.isEmpty ? [".git"] : server.rootMarkers)
        }
        let link = LSPDocumentLink(uri: uri, text: text, version: 1)
        lsp = link
        Task {
            var connected: [LSPClient] = []
            for (server, root) in zip(configs, roots) {
                do {
                    let client = try await self.servers.connection(config: server, root: root)
                    let key = LanguageServerManager.ConnectionKey(name: server.name, root: root.path)
                    let already = await self.servers.isOpen(key: key, uri: uri)
                    client.onDiagnostics = { [weak self] diagURI, diags in
                        Task { @MainActor [weak self] in
                            guard let self, diagURI == self.fileURL?.absoluteString else { return }
                            self.diagnostics = diags
                        }
                    }
                    client.onApplyEdit = { [weak self] edit in
                        Task { @MainActor [weak self] in
                            self?.applyWorkspaceEdit(edit)
                        }
                    }
                    if !already {
                        client.didOpen(uri: uri, languageId: language, version: 1, text: text)
                        await self.servers.trackOpen(key: key, uri: uri)
                    }
                    connected.append(client)
                    self.message = "LSP: \(server.name)"
                } catch {
                    self.message = ""
                }
            }
            guard self.lsp === link else { return }
            link.attach(connected)
        }
    }

    private func stopLSP() {
        lsp?.close()
        lsp = nil
        clearCompletions()
        if !diagnostics.isEmpty { diagnostics = [] }
    }

    private func lspDidSave(_ url: URL) {
        guard fileURL == url else { return }
        lsp?.didSave(text: engine.text)
    }

    private func rebuildDiagnosticRanges() {
        diagnosticRanges = diagnostics.map { diag in
            let start = engine.buffer.offset(of: diag.range.start.textPosition)
            let end = engine.buffer.offset(of: diag.range.end.textPosition)
            return (NSRange(location: start, length: max(0, end - start)), diag.severity)
        }
        guard let editor else { return }
        let current = editor.diagnosticRanges
        let changed = current.count != diagnosticRanges.count
            || current.map(\.0) != diagnosticRanges.map(\.0)
        guard changed else { return }
        editor.diagnosticRanges = diagnosticRanges
        editor.queueRestyle()
    }

    private func diagnosticMessage(at cursor: Int) -> String? {
        for (index, range) in diagnosticRanges.enumerated() where diagnostics.indices.contains(index) {
            let ns = range.0
            if ns.length == 0 {
                if cursor == ns.location { return diagnostics[index].message }
            } else if cursor >= ns.location, cursor < ns.location + ns.length {
                return diagnostics[index].message
            }
        }
        return nil
    }

    private func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func applyPendingJump(for url: URL) {
        let path = url.standardizedFileURL.path
        guard let target = pendingJumps.removeValue(forKey: path) else { return }
        jump(to: target)
    }

    private func referencePreview(_ location: Location, currentURI: String, text: String) -> String {
        let same = location.uri == currentURI || location.fileURL?.path == fileURL?.path
        guard same else { return location.fileURL?.path ?? location.uri }
        let lines = LineIndex(text)
        let line = location.range.start.line
        guard line >= 0, line < lines.lineCount else { return "" }
        let content = lines.line(line).content
        let units = text.utf16
        let lower = units.index(units.startIndex, offsetBy: content.lowerBound)
        let upper = units.index(lower, offsetBy: content.count)
        return String(units[lower..<upper]) ?? ""
    }

    private func applyCodeAction(_ action: CodeAction) {
        if let edit = action.edit {
            applyWorkspaceEdit(edit)
        }
        guard let command = action.command else { return }
        let name = command.command
        let arguments = command.arguments
        guard let link = lsp else {
            if action.edit == nil { message = "No language server" }
            return
        }
        Task {
            let clients = link.requestClients()
            guard let client = clients.first(where: \.isRunning) else {
                if action.edit == nil { self.message = "No language server" }
                return
            }
            do {
                _ = try await client.executeCommand(command: name, arguments: arguments)
            } catch {
                self.message = error.localizedDescription
            }
        }
    }

    func applyWorkspaceEdit(_ edit: WorkspaceEdit) {
        guard let url = fileURL else {
            message = "Edit applies to another file"
            return
        }
        let edits = edit.bufferEdits(in: engine.text, file: url).map {
            TextEdit(range: $0.range, replacement: $0.replacement)
        }
        let foreign = edit.containsEdits(outside: url)
        if edits.isEmpty {
            if foreign { message = "Edit applies to another file" }
            return
        }
        let result = engine.applyHostEdits(edits)
        apply(result)
        if foreign { message = "Edit applies to another file" }
    }

    func runShell(_ command: String) {
        let root = rootURL
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Self.runHookProcess(command: command, root: root)
            }.value
            switch result {
            case .open(let path, let line, let column):
                let absolute = path.hasPrefix("/") ? path : root.appendingPathComponent(path).path
                self.openTarget(LaunchTarget(path: absolute, line: line, column: column))
            case .status(let text):
                self.message = text
            }
        }
    }

    nonisolated private static func runHookProcess(command: String, root: URL) -> HookResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", command]
        proc.currentDirectoryURL = root
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        do {
            try proc.run()
        } catch {
            return .status(error.localizedDescription)
        }
        let (out, err) = ContentSearch.drain(
            stdout: stdout.fileHandleForReading,
            stderr: stderr.fileHandleForReading,
            process: proc
        )
        let outText = String(data: out, encoding: .utf8) ?? ""
        let errText = String(data: err, encoding: .utf8) ?? ""
        return ShellHook.interpret(stdout: outText, stderr: errText, status: proc.terminationStatus)
    }

    private func refreshStatus() {
        setIfChanged(\.status, engine.mode.displayName)
        setIfChanged(\.modified, engine.isModified)
        if engine.mode == .commandLine || engine.mode == .search {
            setIfChanged(\.message, engine.commandLine)
        }
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
