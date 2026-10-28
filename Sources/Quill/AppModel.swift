import AppKit
import Foundation
import Observation
import QuillLSP
import QuillSearch
import QuillVim

@MainActor
@Observable
final class AppModel {
    let config: QuillConfig
    let commands = QuillSearch.CommandRegistry()
    let document: Document
    private(set) var lsp: LSPLink?
    var prompt: Prompt = .none { didSet { noteInterface() } }
    var theme: QuillTheme
    var themeChoice: ThemeChoice = .system
    var themeIdentity = 0 { didSet { noteInterface() } }
    var focusMode = false { didSet { noteInterface() } }
    var status = "NORMAL" { didSet { noteInterface() } }
    var cursorLabel = "1:1" { didSet { noteInterface() } }
    var message = "" { didSet { noteInterface() } }
    var completions: [String] = [] { didSet { noteInterface() } }
    /// `-1` until Ctrl-n/p or an arrow chooses a row. The first Ctrl-n selects the first match.
    var completionIndex = -1 { didSet { noteInterface() } }
    var diagnostics: [Diagnostic] = [] {
        didSet { rebuildDiagnosticRanges() }
    }
    /// UTF-16 ranges computed once when diagnostics arrive.
    var diagnosticRanges: [(NSRange, Int)] = [] { didSet { noteInterface() } }
    /// Session override of `config.images`. The command palette toggles this.
    var showImages = true { didSet { noteInterface() } }
    let session: AppSession
    /// The live text view. Nil in tests that drive the engine without a window.
    @ObservationIgnored
    weak var editor: VimTextView?
    /// The AppKit shell syncs chrome from here. SwiftUI is not on the first frame, so nothing else is observing these properties.
    @ObservationIgnored
    var onInterfaceChange: (@MainActor () -> Void)?
    @ObservationIgnored
    private var deliveringInterface = false

    func noteInterface() {
        if deliveringInterface { return }
        deliveringInterface = true
        defer { deliveringInterface = false }
        onInterfaceChange?()
    }

    init(
        config: QuillConfig,
        home: URL,
        notice: String? = nil,
        themeChoice: ThemeChoice = .system,
        isDark: @escaping @MainActor () -> Bool
    ) {
        self.config = config
        self.session = AppSession(home: home, isDark: isDark)
        self.document = Document(engine: Engine(clipboard: PasteboardClipboard()), root: home)
        self.themeChoice = themeChoice
        self.theme = QuillTheme.current(
            fontFamily: config.font,
            fontSize: config.fontSize,
            columnCharacters: config.columnWidth,
            scheme: themeChoice,
            systemIsDark: isDark()
        )
        self.showImages = config.images
        if let notice, !notice.isEmpty { self.message = notice }
        session.hop.model = self
        document.onReplaced = { [weak self] in self?.documentReplaced() }
        let commandsBegan = StartupProbe.begin("commandsMs")
        installCommands()
        StartupProbe.end("commandsMs", commandsBegan)
        let applyBegan = StartupProbe.begin("configApplyMs")
        config.apply(to: self)
        StartupProbe.end("configApplyMs", applyBegan)
    }

    func installLSP(_ link: LSPLink?) {
        lsp = link
    }

    func toggleImages() {
        showImages.toggle()
        message = showImages ? "images on" : "images off"
    }

    func toggleFocus() { focusMode.toggle() }

    func afterEdit(_ result: EngineResult) {
        if !document.engine.statusMessage.isEmpty {
            setIfChanged(\.message, document.engine.statusMessage)
        }
        if document.engine.mode == .commandLine || document.engine.mode == .search {
            setIfChanged(\.message, document.engine.commandLine)
        }
        if result.didChangeText, !document.isDirectory {
            lsp?.didEdit(result.edits)
            if document.engine.mode == .insert {
                updateWikilinkCompletion()
            } else if !completions.isEmpty {
                clearCompletions()
            }
        }
        for action in result.actions { perform(action) }
        refreshStatus()
    }

    /// Host edit: the text view applies it, then `afterEdit` runs. Without a view, only the model updates.
    func apply(_ result: EngineResult) {
        guard let editor else {
            afterEdit(result)
            return
        }
        editor.applyResult(result)
        if editor.string != document.engine.text {
            editor.reload()
        } else if editor.selectedRange().location != document.engine.cursor {
            editor.setSelectedRange(NSRange(location: document.engine.cursor, length: 0))
        }
    }

    func setIfChanged<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppModel, T>, _ value: T) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
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

    func refreshStatus() {
        let wasModified = document.modified
        let title = document.title
        document.noteEdit()
        setIfChanged(\.status, document.engine.mode.displayName)
        let pos = document.engine.buffer.position(of: document.engine.cursor)
        setIfChanged(\.cursorLabel, "\(pos.line + 1):\(pos.utf16Column + 1)")
        if document.engine.mode == .commandLine || document.engine.mode == .search {
            setIfChanged(\.message, document.engine.commandLine)
        }
        // Mode and message notify on their own. Title and the modified mark live on the document.
        if wasModified != document.modified || title != document.title {
            noteInterface()
        }
    }

    func documentReplaced() {
        session.completionGeneration += 1
        session.hoverGeneration += 1
        session.completionQuery = nil
        completionIndex = -1
        if !completions.isEmpty { completions = [] }
        if !diagnostics.isEmpty { diagnostics = [] }
        rebuildKeymap()
        if let editor {
            _ = editor.applyDocumentChrome(from: self)
            editor.reload()
        }
        refreshStatus()
        noteInterface()
        if let url = document.url, let target = document.takeJump(for: url) {
            jump(to: target)
        }
        scheduleLSP()
    }
}
