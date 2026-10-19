import AppKit
import QuillFS
import QuillLSP
import QuillMarkdown
import QuillSearch
import QuillText
import QuillVim
import QuillWorkspace

enum PickerKind: Equatable {
    case files, grep, references, codeAction, commands
}

enum PendingNavigation {
    case open(URL)
    case newFile
    case close(NSWindow)
    case terminate
}

enum Prompt {
    case none
    case picker(PickerSession)
    case confirmFilesystem(ops: [FSOperation], warning: String)
    case unsaved(PendingNavigation)
}

@MainActor
final class PickerSession {
    let id: Int
    let kind: PickerKind
    let picker: PickerEngine
    var restore: (Mode, Int)?
    var codeActions: [CodeAction] = []

    init(id: Int, kind: PickerKind, picker: PickerEngine, restore: (Mode, Int)?) {
        self.id = id
        self.kind = kind
        self.picker = picker
        self.restore = restore
    }
}

extension AppModel {
    func beginPromptWork() -> Int {
        session.promptEpoch += 1
        return session.promptEpoch
    }

    func promptIsCurrent(_ token: Int, generation: Int) -> Bool {
        token == session.promptEpoch && document.generation == generation
    }

    /// Escape while nothing is showing invalidates a picker that has not appeared yet.
    func noteEscape() {
        guard case .none = prompt else { return }
        session.promptEpoch += 1
    }

    func clearPrompt() {
        session.promptEpoch += 1
        prompt = .none
    }

    func dismissConfirm() {
        guard case .confirmFilesystem = prompt else { return }
        clearPrompt()
    }

    func presentFilePicker() {
        let token = beginPromptWork()
        let generation = document.generation
        let root = document.rootURL
        Task {
            await self.session.search.beforeIndex()
            guard self.promptIsCurrent(token, generation: generation) else { return }
            let ignore = await IgnoreCache.shared.rules(for: root)
            await self.session.search.index.rebuild(root: root, ignore: ignore)
            guard self.promptIsCurrent(token, generation: generation) else { return }
            let paths = await self.session.search.index.relativePaths()
            guard self.promptIsCurrent(token, generation: generation) else { return }
            let items = paths.map { path in
                PickerItem(title: path, payload: root.appendingPathComponent(path).path, preview: "")
            }
            let picker = PickerEngine(source: items)
            let opened = PickerSession(id: token, kind: .files, picker: picker, restore: nil)
            self.prompt = .picker(opened)
            self.message = "<leader>sf"
            self.loadPreview(opened)
        }
    }

    func presentGrepPicker() {
        let token = beginPromptWork()
        let picker = PickerEngine()
        picker.onQueryChange = { [weak self] query in
            self?.scheduleGrep(query)
        }
        prompt = .picker(PickerSession(id: token, kind: .grep, picker: picker, restore: nil))
        message = "<leader>sg"
    }

    func handlePicker(_ key: PickerKey) {
        guard case .picker(let opened) = prompt else { return }
        if opened.kind == .commands, key == .escape {
            dismissCommandPalette(restore: true)
            return
        }
        switch opened.picker.handle(key) {
        case .none:
            if opened.kind != .commands { loadPreview(opened) }
        case .close:
            if opened.kind == .commands {
                dismissCommandPalette(restore: true)
            } else {
                clearPrompt()
            }
        case .confirm:
            if opened.kind == .commands {
                let id = opened.picker.selected?.payload
                dismissCommandPalette(restore: true)
                if let id, !runCommand(id) { message = "Unavailable" }
                return
            }
            let item = opened.picker.selected
            let kind = opened.kind
            let action = codeAction(in: opened, item: item)
            clearPrompt()
            guard let item else { return }
            if let action {
                applyCodeAction(action)
            } else {
                openPickerPayload(item.payload, columnUnit: kind == .references ? .utf16 : .character)
            }
        }
    }

    func openPickerPayload(_ payload: String, columnUnit: LaunchTarget.ColumnUnit = .character) {
        let split = LaunchRequest.splitLocation(payload)
        openTarget(LaunchTarget(path: split.path, line: split.line, column: split.column, columnUnit: columnUnit))
    }

    func jump(to target: LaunchTarget) {
        guard let line = target.line else { return }
        jumpToLine(line, column: target.column, unit: target.columnUnit)
    }

    func jumpToLine(_ line: Int, column: Int? = nil, unit: LaunchTarget.ColumnUnit = .character) {
        let index = min(max(0, line - 1), document.engine.buffer.lastLine)
        let col = max(1, column ?? 1) - 1
        let offset: Int
        switch unit {
        case .character:
            offset = document.engine.buffer.offset(line: index, graphemeColumn: col)
        case .utf16:
            offset = document.engine.buffer.offset(of: TextPosition(line: index, utf16Column: col))
        }
        apply(document.engine.moveCursor(to: offset))
    }

    func findReferences() {
        guard let url = document.url, !document.isDirectory else {
            message = "No language server"
            return
        }
        let position = LSPPosition(document.engine.buffer.position(of: document.engine.cursor))
        let uri = url.absoluteString
        let text = document.engine.text
        guard let link = lsp else {
            message = "No language server"
            return
        }
        let token = beginPromptWork()
        let generation = document.generation
        Task {
            let clients = link.requestClients()
            guard let client = clients.first(where: \.isRunning) else {
                self.message = "No language server"
                return
            }
            do {
                let locations = try await client.references(uri: uri, position: position)
                guard self.promptIsCurrent(token, generation: generation) else { return }
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
                guard self.promptIsCurrent(token, generation: generation) else { return }
                let picker = PickerEngine(source: items)
                self.prompt = .picker(PickerSession(id: token, kind: .references, picker: picker, restore: nil))
                self.message = "gr"
            } catch {
                guard self.promptIsCurrent(token, generation: generation) else { return }
                self.message = error.localizedDescription
            }
        }
    }

    func presentCodeActions() {
        guard let url = document.url, !document.isDirectory else {
            message = "No language server"
            return
        }
        let range: LSPRange
        if let selection = document.engine.visualSelection {
            range = LSPRange(
                start: LSPPosition(document.engine.buffer.position(of: selection.lowerBound)),
                end: LSPPosition(document.engine.buffer.position(of: selection.upperBound))
            )
        } else {
            let position = LSPPosition(document.engine.buffer.position(of: document.engine.cursor))
            range = LSPRange(start: position, end: position)
        }
        let uri = url.absoluteString
        let context = diagnostics
        guard let link = lsp else {
            message = "No language server"
            return
        }
        let token = beginPromptWork()
        let generation = document.generation
        Task {
            let clients = link.requestClients()
            guard let client = clients.first(where: \.isRunning) else {
                self.message = "No language server"
                return
            }
            do {
                let actions = try await client.codeAction(uri: uri, range: range, diagnostics: context)
                    .sorted { $0.isPreferred && !$1.isPreferred }
                guard self.promptIsCurrent(token, generation: generation) else { return }
                if actions.isEmpty {
                    self.message = "No code actions"
                    return
                }
                let items = actions.enumerated().map { index, action in
                    PickerItem(
                        title: action.title,
                        subtitle: action.kind ?? "",
                        payload: String(index),
                        preview: action.kind ?? action.title
                    )
                }
                let picker = PickerEngine(source: items)
                let opened = PickerSession(id: token, kind: .codeAction, picker: picker, restore: nil)
                opened.codeActions = actions
                self.prompt = .picker(opened)
                self.message = "<leader>ca"
            } catch {
                guard self.promptIsCurrent(token, generation: generation) else { return }
                self.message = error.localizedDescription
            }
        }
    }

    func handleCompletionKey(_ event: KeyEvent) -> Bool {
        if event.key == .escape { noteEscape() }
        guard document.engine.mode == .insert, !completions.isEmpty else { return false }
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
        let cursor = document.engine.cursor
        let line = document.engine.buffer.line(document.engine.buffer.lineIndex(containing: cursor))
        let end = min(max(cursor, line.start), line.contentEnd)
        let fragment = document.engine.buffer.substring(line.start..<end)
        guard let prefix = WikilinkQuery.prefix(before: end - line.start, in: fragment) else { return }
        let start = end - prefix.utf16.count
        apply(document.engine.applyHostEdit(replacing: start..<end, with: name))
        clearCompletions()
    }

    func followWikilink() {
        if let name = WikilinkQuery.at(cursor: document.engine.cursor, in: document.engine.text) {
            jumpToFilename(name)
        }
    }

    func jumpToFilename(_ name: String) {
        let generation = document.generation
        let cursor = document.engine.cursor
        let root = document.rootURL
        Task {
            if await self.session.search.index.root?.path != root.path {
                let ignore = await IgnoreCache.shared.rules(for: root)
                guard self.document.generation == generation, self.document.engine.cursor == cursor else { return }
                await self.session.search.index.rebuild(root: root, ignore: ignore)
            }
            guard self.document.generation == generation, self.document.engine.cursor == cursor else { return }
            let files = await self.session.search.index.files
            guard self.document.generation == generation, self.document.engine.cursor == cursor else { return }
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

    func updateWikilinkCompletion() {
        guard document.engine.mode == .insert else {
            clearCompletions()
            return
        }
        let cursor = document.engine.cursor
        let line = document.engine.buffer.line(document.engine.buffer.lineIndex(containing: cursor))
        let end = min(max(cursor, line.start), line.contentEnd)
        let fragment = document.engine.buffer.substring(line.start..<end)
        guard let prefix = WikilinkQuery.prefix(before: end - line.start, in: fragment) else {
            clearCompletions()
            return
        }
        if prefix == session.completionQuery { return }
        session.completionQuery = prefix
        session.completionGeneration += 1
        let token = session.completionGeneration
        let generation = document.generation
        let root = document.rootURL
        Task {
            if await self.session.search.index.root?.path != root.path {
                await self.session.search.index.rebuild(root: root, ignore: IgnoreRules())
            }
            guard token == self.session.completionGeneration, self.document.generation == generation else { return }
            guard self.document.engine.mode == .insert else { return }
            let names = await self.session.search.index.files.map { $0.deletingPathExtension().lastPathComponent }
            guard token == self.session.completionGeneration, self.document.generation == generation else { return }
            guard self.document.engine.mode == .insert else { return }
            self.completions = Fuzzy.rank(query: prefix, candidates: Array(Set(names))).prefix(8).map(\.value)
            self.completionIndex = -1
        }
    }

    func clearCompletions() {
        session.completionGeneration += 1
        session.completionQuery = nil
        completionIndex = -1
        if !completions.isEmpty { completions = [] }
    }

    func scheduleGrep(_ query: String) {
        guard case .picker(let opened) = prompt, opened.kind == .grep else { return }
        let token = opened.id
        let generation = document.generation
        session.search.grepTask?.cancel()
        let root = document.rootURL
        session.search.grepTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 40_000_000)
            if Task.isCancelled { return }
            guard self.promptIsCurrent(token, generation: generation) else { return }
            let ignore = await IgnoreCache.shared.rules(for: root)
            if Task.isCancelled { return }
            guard self.promptIsCurrent(token, generation: generation) else { return }
            let hits = await self.session.search.session.search(root: root, query: query, ignore: ignore)
            guard self.promptIsCurrent(token, generation: generation) else { return }
            let items = hits.map { hit -> PickerItem in
                let absolute = hit.path.hasPrefix("/") ? hit.path : root.appendingPathComponent(hit.path).path
                return PickerItem(
                    title: "\(hit.path):\(hit.line)",
                    subtitle: hit.snippet,
                    payload: "\(absolute):\(hit.line)",
                    preview: ""
                )
            }
            guard case .picker(let current) = self.prompt, current.id == token else { return }
            current.picker.replaceItems(items)
        }
    }

    func loadPreview(_ opened: PickerSession) {
        guard opened.kind == .files,
              let payload = opened.picker.selected?.payload,
              opened.picker.selected?.preview.isEmpty == true else { return }
        let token = opened.id
        let url = URL(fileURLWithPath: payload)
        Task {
            let text = await self.session.search.readPreview(url)
            guard case .picker(let current) = self.prompt, current.id == token else { return }
            current.picker.updatePreview(payload: payload, text: text)
        }
    }

    func applyCodeAction(_ action: CodeAction) {
        if let edit = action.edit {
            applyWorkspaceEdit(edit)
        }
        guard let command = action.command else { return }
        let generation = document.generation
        let name = command.command
        let arguments = command.arguments
        guard let link = lsp else {
            if action.edit == nil { message = "No language server" }
            return
        }
        Task {
            let clients = link.requestClients()
            guard self.document.generation == generation else { return }
            guard let client = clients.first(where: \.isRunning) else {
                if action.edit == nil { self.message = "No language server" }
                return
            }
            do {
                _ = try await client.executeCommand(command: name, arguments: arguments)
            } catch {
                guard self.document.generation == generation else { return }
                self.message = error.localizedDescription
            }
        }
    }

    private func codeAction(in opened: PickerSession, item: PickerItem?) -> CodeAction? {
        guard opened.kind == .codeAction, let item, let index = Int(item.payload) else { return nil }
        guard opened.codeActions.indices.contains(index) else { return nil }
        return opened.codeActions[index]
    }

    private func referencePreview(_ location: Location, currentURI: String, text: String) -> String {
        let same = location.uri == currentURI || location.fileURL?.path == document.url?.path
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
}
