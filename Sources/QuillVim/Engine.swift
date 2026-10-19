/// A from-scratch vim engine: parse count, then operator, then motion or text object.
import QuillText
/// Motions and text objects return ranges; operators act on those ranges so they compose.
/// Every change is recorded as a replayable command for `.` and grouped undo.
public final class Engine {
    public private(set) var buffer: TextBuffer
    public var mode: Mode = .normal
    /// Where buffer lines break into screen lines. The host's text view, or no wrapping.
    public var layout: any ScreenLayout
    public var clipboard: any Clipboard
    public var shiftWidth: Int = 2
    /// When true, leaving insert mode asks the host to pad the table under the cursor.
    public var formatTablesOnInsertLeave = false
    /// When true, Enter in normal mode asks the host to open the current line
    /// (directory listings) instead of moving down.
    public var openOnEnter: Bool = false
    /// Lines Ctrl-d / Ctrl-u move when the user did not type a count.
    /// The host sets this to half the visible window. A count updates it, matching vim's `scroll`.
    public var scrollLineCount: Int = 10
    /// Leader key in normal mode. Space by default; configurable by the host.
    public var leaderKey: Character = " "
    /// Sequence → action after the leader. Host loads this from config.
    public var keymap = Keymap()
    public var leaderBindings: [String: HostAction] = [
        "sf": .findFiles,
        "sg": .liveGrep,
        "ca": .codeAction,
        // `<leader>t*` is reserved for toggles. `tt` is the appearance toggle.
        "tt": .toggleTheme,
    ]
    public private(set) var isModified: Bool = false
    public private(set) var statusMessage: String = ""
    public private(set) var commandLine: String = ""
    public private(set) var lastEdit: TextEdit?

    var unnamed = Register.empty
    var registers = RegisterStore()
    var visualAnchor: Int = 0
    private var jumpBack: [Int] = []
    private var jumpForward: [Int] = []

    var count: Int?
    var operatorKind: OperatorKind?
    var operatorCount: Int?
    var pendingG = false
    var pendingQuote = false
    var pendingRegister: RegisterName = .unnamed
    var pendingFind: FindKind?
    var pendingTextObjectInner: Bool?
    var pendingLeader: String?
    var pendingMarkSet = false
    var pendingMarkJump: Character?
    var mapPrefix = ""

    var lastFind: (FindKind, Character)?
    var searchPattern: String = ""
    var searchForward: Bool = true
    var commandHistory: [String] = []
    var historyCursor: Int = 0

    private struct UndoEntry {
        var forward: [TextEdit]
        var inverse: [TextEdit]
        var cursorBefore: Int
        var cursorAfter: Int
        var stamp: Int
    }

    private var undoStack: [UndoEntry] = []
    private var redoStack: [UndoEntry] = []
    private var strokeEdits: [TextEdit] = []
    private var groupDepth = 0
    private var groupForward: [TextEdit] = []
    /// Start of the last line when a group began, if that line had content and no
    /// newline. Edits in the group carry it along; see `keepEmptiedLastLine`.
    private var groupBareLastLineStart: Int?
    private var groupInverse: [TextEdit] = []
    private var groupCursorBefore = 0
    private var nextStamp = 1
    private var currentStamp = 0
    private var savedStamp = 0
    var lastRepeatable: Repeatable?

    var insertKind: InsertKind = .i
    var insertCount: Int = 1
    var insertBaseline: String = ""
    var insertBaselineCursor: Int = 0
    var insertStarted: Bool = false

    public init(
        text: String = "",
        cursor: Int = 0,
        clipboard: (any Clipboard)? = nil,
        layout: (any ScreenLayout)? = nil
    ) {
        self.buffer = TextBuffer(text: text, cursor: cursor)
        self.clipboard = clipboard ?? MemoryClipboard()
        self.layout = layout ?? LogicalLineLayout.shared
    }

    /// Buffer and screen lines for the current text and layout.
    public var screen: ScreenModel {
        ScreenModel(buffer: buffer, layout: layout)
    }

    public var text: String { buffer.text }
    public var cursor: Int { buffer.cursor }
    public var unnamedRegister: Register { unnamed }

    public var visualSelection: Range<Int>? {
        guard mode.isVisual else { return nil }
        let a = min(visualAnchor, buffer.cursor)
        let b = max(visualAnchor, buffer.cursor)
        if mode == .visualLine {
            let l1 = buffer.lineIndex(containing: a)
            let l2 = buffer.lineIndex(containing: b)
            return buffer.linesRange(from: l1, through: l2)
        }
        let end = b < buffer.count ? buffer.graphemeSpan(containing: b).upperBound : buffer.count
        return a..<max(a, end)
    }

    public func load(text: String, cursor: Int = 0) {
        buffer = TextBuffer(text: text, cursor: cursor)
        resetCurswant()
        mode = .normal
        isModified = false
        undoStack = []
        redoStack = []
        groupDepth = 0
        groupForward = []
        groupInverse = []
        groupBareLastLineStart = nil
        strokeEdits = []
        nextStamp = 1
        currentStamp = 0
        savedStamp = 0
        lastRepeatable = nil
        pendingLeader = nil
        resetParser()
        statusMessage = ""
        commandLine = ""
    }

    /// Text of the buffer line containing the cursor, excluding the newline.
    public func lineTextUnderCursor() -> String {
        let line = buffer.lineIndex(containing: buffer.cursor)
        let range = buffer.lineContentRange(at: line)
        return buffer.substring(range)
    }

    public func markSaved() {
        savedStamp = currentStamp
        isModified = false
    }

    /// Host-initiated edit (completion, snippet). Goes through the same funnel as keys.
    @discardableResult
    public func applyHostEdit(replacing range: Range<Int>, with text: String) -> EngineResult {
        let text = LineIndex.normalizingNewlines(text)
        strokeEdits.removeAll(keepingCapacity: true)
        let before = buffer.cursor
        let nested = groupDepth > 0
        if !nested { beginTransaction() }
        replace(range, with: text)
        let width = buffer.measure(text)
        buffer.cursor = buffer.clampedCursor(range.lowerBound + width, normalMode: mode != .insert)
        resetCurswant()
        if !nested { commitTransaction() }
        return finishStroke(EngineResult(didChangeText: true, beep: false, actions: []), cursorBefore: before)
    }

    /// Several host edits (a code action, `workspace/applyEdit`) as one undo group.
    /// Ranges are against the original text. They are applied end-to-start.
    /// An empty list does not mark the buffer modified.
    @discardableResult
    public func applyHostEdits(_ edits: [TextEdit], cursor: Int? = nil) -> EngineResult {
        strokeEdits.removeAll(keepingCapacity: true)
        let before = buffer.cursor
        if edits.isEmpty {
            return finishStroke(.noop, cursorBefore: before)
        }
        let applyOrder = edits.map {
            TextEdit(range: $0.range, replacement: LineIndex.normalizingNewlines($0.replacement))
        }.sorted { lhs, rhs in
            if lhs.range.lowerBound != rhs.range.lowerBound {
                return lhs.range.lowerBound > rhs.range.lowerBound
            }
            return lhs.range.upperBound > rhs.range.upperBound
        }
        let nested = groupDepth > 0
        if !nested { beginTransaction() }
        for edit in applyOrder {
            replace(edit.range, with: edit.replacement)
        }
        if let cursor {
            buffer.cursor = buffer.clampedCursor(cursor, normalMode: mode != .insert)
            resetCurswant()
        } else if let earliest = applyOrder.last {
            let width = buffer.measure(earliest.replacement)
            buffer.cursor = buffer.clampedCursor(earliest.range.lowerBound + width, normalMode: mode != .insert)
            resetCurswant()
        }
        if !nested { commitTransaction() }
        return finishStroke(EngineResult(didChangeText: true, beep: false, actions: []), cursorBefore: before)
    }

    /// Install a directory-line identity at the start of `line`.
    public func setDirectoryAnchor(line: Int, id: UInt64, sourcePath: String, isDirectory: Bool) {
        guard line >= 0, line <= buffer.lastLine else { return }
        let offset = buffer.line(line).start
        buffer.addAnchor(Anchor(
            id: AnchorID(raw: id),
            offset: offset,
            gravity: .left,
            kind: .directoryEntry(sourcePath: sourcePath, isDirectory: isDirectory, transfer: .identity)
        ))
    }

    /// Drag-select in the text view. The anchor stays put; the caret follows the mouse.
    public func beginMouseSelection(anchor: Int, caret: Int) {
        visualAnchor = min(anchor, buffer.count)
        mode = .visual
        buffer.cursor = buffer.clampedCursor(max(anchor, caret), normalMode: true)
        resetCurswant()
    }

    public func moveCursor(to offset: Int) {
        buffer.cursor = buffer.clampedCursor(offset, normalMode: mode != .insert)
        resetCurswant()
    }

    @discardableResult
    public func type(_ notation: String) -> EngineResult {
        var last = EngineResult.noop
        for event in KeyEvent.parse(notation) {
            last = handle(event)
        }
        return last
    }

    @discardableResult
    public func handle(_ event: KeyEvent) -> EngineResult {
        strokeEdits.removeAll(keepingCapacity: true)
        let before = buffer.cursor
        let result = dispatch(event)
        return finishStroke(result, cursorBefore: before)
    }

    private func finishStroke(_ result: EngineResult, cursorBefore: Int) -> EngineResult {
        var result = result
        result.edits = strokeEdits
        result.cursorBefore = cursorBefore
        result.cursorAfter = buffer.cursor
        lastEdit = strokeEdits.last
        return result
    }

    private func dispatch(_ event: KeyEvent) -> EngineResult {
        switch mode {
        case .insert:
            return handleInsert(event)
        case .commandLine:
            return handleCommandLine(event)
        case .search:
            return handleSearchCollect(event)
        case .replaceChar:
            return handleReplaceChar(event)
        case .findChar:
            return handleFindChar(event)
        case .normal, .visual, .visualLine, .operatorPending:
            return handleNormalLike(event)
        }
    }

    // MARK: Parser

    private func resetParser() {
        count = nil
        operatorKind = nil
        operatorCount = nil
        pendingG = false
        pendingQuote = false
        pendingRegister = .unnamed
        pendingFind = nil
        pendingTextObjectInner = nil
        pendingLeader = nil
        pendingMarkSet = false
        pendingMarkJump = nil
        mapPrefix = ""
        if mode == .operatorPending {
            mode = .normal
        }
    }

    private func effectiveCount() -> Int {
        let a = operatorCount ?? 1
        let b = count ?? 1
        if operatorCount != nil || count != nil {
            return max(1, a * b)
        }
        return 1
    }

    private func handleNormalLike(_ event: KeyEvent) -> EngineResult {
        switch event.key {
        case .escape:
            resetParser()
            mode = .normal
            buffer.clampCursor(normalMode: true)
            return .noop
        case .enter:
            if openOnEnter, operatorKind == nil, !mode.isVisual, pendingLeader == nil {
                return EngineResult(didChangeText: false, beep: false, actions: [.openUnderCursor])
            }
            return applyMotion(.down, find: nil)
        case .backspace:
            return applyMotion(.left, find: nil)
        case .left:
            return applyMotion(.left, find: nil)
        case .right:
            return applyMotion(.right, find: nil)
        case .up:
            return applyMotion(.up, find: nil)
        case .down:
            return applyMotion(.down, find: nil)
        case .tab, .delete:
            return .noop
        case .ctrl(let c):
            if c == "r" {
                return redo()
            }
            if c == "o" {
                return jumpList(older: true)
            }
            if c == "i" {
                return jumpList(older: false)
            }
            if c == "d" || c == "u" {
                if let explicit = count {
                    scrollLineCount = max(1, explicit)
                }
                count = max(1, scrollLineCount)
                return applyMotion(c == "d" ? .down : .up, find: nil)
            }
            return beepResult()
        case .character(let ch):
            return handleNormalCharacter(ch)
        case .text(let text):
            guard let ch = text.first else { return beepResult() }
            return handleNormalCharacter(ch)
        }
    }

    private func handleNormalCharacter(_ ch: Character) -> EngineResult {
        if pendingMarkSet {
            pendingMarkSet = false
            return setMark(ch)
        }
        if pendingMarkJump != nil {
            pendingMarkJump = nil
            return jumpToMark(ch)
        }
        if parserIsIdle {
            let next = mapPrefix + String(ch)
            switch keymap.lookup(next) {
            case .command(let name):
                mapPrefix = ""
                resetParser()
                return EngineResult(didChangeText: false, beep: false, actions: [.command(name)])
            case .prefix:
                mapPrefix = next
                return .noop
            case .none:
                if !mapPrefix.isEmpty {
                    mapPrefix = ""
                    return beepResult()
                }
            }
        }
        if let prefix = pendingLeader {
            return handleLeader(prefix, ch)
        }
        if pendingQuote {
            pendingQuote = false
            switch ch {
            case "+", "*":
                pendingRegister = .clipboard
            case "\"":
                pendingRegister = .unnamed
            case "_":
                pendingRegister = .blackHole
            case "-":
                pendingRegister = .smallDelete
            case ".":
                pendingRegister = .lastInsert
            case ":":
                pendingRegister = .lastCommand
            case "/":
                pendingRegister = .lastSearch
            case let digit where digit.isNumber:
                pendingRegister = .numbered(digit.wholeNumberValue ?? 0)
            case let letter where letter.isLetter:
                pendingRegister = .named(letter)
            default:
                return beepResult()
            }
            return .noop
        }

        if pendingG {
            pendingG = false
            if ch == "g" {
                let n = count ?? 1
                count = n
                return applyMotion(.fileStart, find: nil)
            }
            if ch == "j" {
                return applyMotion(.down, find: nil)
            }
            if ch == "k" {
                return applyMotion(.up, find: nil)
            }
            if ch == "0" {
                return applyMotion(.lineStart, find: nil)
            }
            if ch == "$" {
                return applyMotion(.lineEnd, find: nil)
            }
            if ch == "d", operatorKind == nil, !mode.isVisual {
                resetParser()
                return EngineResult(didChangeText: false, beep: false, actions: [.goToDefinition])
            }
            if ch == "r", operatorKind == nil, !mode.isVisual {
                resetParser()
                return EngineResult(didChangeText: false, beep: false, actions: [.findReferences])
            }
            return beepResult()
        }

        if let inner = pendingTextObjectInner {
            pendingTextObjectInner = nil
            guard let object = TextObjectKind.parse(inner: inner, specifier: ch) else {
                resetParser()
                return beepResult()
            }
            return applyTextObject(object)
        }

        if ch.isNumber, let digit = ch.wholeNumberValue {
            if ch == "0" && count == nil {
                return applyMotion(.screenLineStart, find: nil)
            }
            count = (count ?? 0) * 10 + digit
            return .noop
        }

        if let inner = iaSpecifier(ch), operatorKind != nil || mode.isVisual {
            pendingTextObjectInner = inner
            return .noop
        }

        if let op = OperatorKind(character: ch) {
            return handleOperatorKey(op)
        }

        switch ch {
        case "\"":
            pendingQuote = true
            return .noop
        case "m":
            if operatorKind == nil, !mode.isVisual {
                pendingMarkSet = true
                return .noop
            }
            return beepResult()
        case "'", "`":
            if operatorKind == nil, !mode.isVisual {
                pendingMarkJump = ch
                return .noop
            }
            return beepResult()
        case "g":
            pendingG = true
            return .noop
        case "v":
            return enterVisual(line: false)
        case "V":
            return enterVisual(line: true)
        case "h":
            return applyMotion(.left, find: nil)
        case "j":
            return applyMotion(.down, find: nil)
        case "k":
            return applyMotion(.up, find: nil)
        case "l":
            return applyMotion(.right, find: nil)
        case "w":
            return applyMotion(.word, find: nil)
        case "W":
            return applyMotion(.WORD, find: nil)
        case "e":
            return applyMotion(.wordEnd, find: nil)
        case "E":
            return applyMotion(.WORDEnd, find: nil)
        case "b":
            return applyMotion(.wordBack, find: nil)
        case "B":
            return applyMotion(.WORDBack, find: nil)
        case "^":
            return applyMotion(.firstNonBlank, find: nil)
        case "$":
            return applyMotion(.screenLineEnd, find: nil)
        case "{":
            return applyMotion(.paragraph(forward: false), find: nil)
        case "}":
            return applyMotion(.paragraph(forward: true), find: nil)
        case "(":
            return applyMotion(.sentence(forward: false), find: nil)
        case ")":
            return applyMotion(.sentence(forward: true), find: nil)
        case "G":
            if count == nil && operatorCount == nil {
                count = 0
            }
            return applyMotion(.gotoLine, find: nil)
        case "f":
            return beginFind(.findForward)
        case "t":
            return beginFind(.tillForward)
        case "F":
            return beginFind(.findBackward)
        case "T":
            return beginFind(.tillBackward)
        case ";":
            return repeatFind(opposite: false)
        case ",":
            return repeatFind(opposite: true)
        case "/", "?":
            return beginSearch(forward: ch == "/")
        case "n":
            return applyMotion(.search(forward: true), find: nil)
        case "N":
            return applyMotion(.search(forward: false), find: nil)
        case "x":
            if mode.isVisual { return applyOperatorToVisual(.delete) }
            return commandDeleteChars(count: effectiveCount(), enterInsert: false)
        case "s":
            if mode.isVisual { return applyOperatorToVisual(.change) }
            return commandDeleteChars(count: effectiveCount(), enterInsert: true)
        case "r":
            mode = .replaceChar
            return .noop
        case "~":
            return toggleCase(count: effectiveCount())
        case "J":
            return joinLines(count: max(2, (count ?? 2)))
        case "u":
            return undo()
        case "p":
            return put(after: true, count: effectiveCount())
        case "P":
            return put(after: false, count: effectiveCount())
        case ".":
            return repeatLast()
        case "i":
            return beginInsert(.i)
        case "a":
            return beginInsert(.a)
        case "I":
            return beginInsert(.I)
        case "A":
            return beginInsert(.A)
        case "o":
            return beginInsert(.o)
        case "O":
            return beginInsert(.O)
        case "D":
            return applyNamedCommand(motion: .screenLineEnd, op: .delete)
        case "C":
            return applyNamedCommand(motion: .screenLineEnd, op: .change)
        case "Y":
            return applyNamedCommand(linewise: true, op: .yank)
        case ":":
            if mode.isVisual { return beepResult() }
            mode = .commandLine
            commandLine = ":"
            historyCursor = commandHistory.count
            return .noop
        case "-":
            if operatorKind == nil, !mode.isVisual {
                resetParser()
                return EngineResult(didChangeText: false, beep: false, actions: [.openParentDirectory])
            }
            return beepResult()
        default:
            if ch == leaderKey, operatorKind == nil, !mode.isVisual {
                pendingLeader = ""
                statusMessage = "<leader>"
                return .noop
            }
            return beepResult()
        }
    }

    private func handleLeader(_ prefix: String, _ ch: Character) -> EngineResult {
        let next = prefix + String(ch)
        if let action = leaderBindings[next] {
            pendingLeader = nil
            statusMessage = ""
            return EngineResult(didChangeText: false, beep: false, actions: [action])
        }
        if leaderBindings.keys.contains(where: { $0.hasPrefix(next) }) {
            pendingLeader = next
            statusMessage = "<leader>" + next
            return .noop
        }
        pendingLeader = nil
        statusMessage = ""
        return beepResult()
    }

    private func iaSpecifier(_ ch: Character) -> Bool? {
        if ch == "i" { return true }
        if ch == "a" { return false }
        return nil
    }

    private func handleOperatorKey(_ op: OperatorKind) -> EngineResult {
        if mode.isVisual {
            return applyOperatorToVisual(op)
        }
        if let pending = operatorKind, pending == op {
            return applyLinewiseOperator(op)
        }
        if operatorKind != nil {
            resetParser()
            return beepResult()
        }
        operatorKind = op
        operatorCount = count
        count = nil
        mode = .operatorPending
        return .noop
    }

    private func beginFind(_ kind: FindKind) -> EngineResult {
        pendingFind = kind
        mode = .findChar
        return .noop
    }

    private func handleFindChar(_ event: KeyEvent) -> EngineResult {
        let restore = operatorKind != nil ? Mode.operatorPending : Mode.normal
        let character: Character?
        switch event.key {
        case .character(let ch): character = ch
        case .text(let text): character = text.first
        default: character = nil
        }
        guard let ch = character, event.key != .escape else {
            mode = restore
            pendingFind = nil
            if event.key == .escape { resetParser() }
            return event.key == .escape ? .noop : beepResult()
        }
        guard let kind = pendingFind else {
            mode = restore
            return beepResult()
        }
        pendingFind = nil
        lastFind = (kind, ch)
        mode = restore
        return applyMotion(.find(kind), find: (kind, ch))
    }

    private func repeatFind(opposite: Bool) -> EngineResult {
        guard var find = lastFind else { return beepResult() }
        if opposite { find.0 = find.0.reversed }
        return applyMotion(.find(find.0), find: find)
    }

    private func beginSearch(forward: Bool) -> EngineResult {
        searchForward = forward
        mode = .search
        commandLine = forward ? "/" : "?"
        return .noop
    }

    private func enterVisual(line: Bool) -> EngineResult {
        if mode.isVisual {
            mode = .normal
            resetParser()
            return .noop
        }
        visualAnchor = buffer.cursor
        mode = line ? .visualLine : .visual
        resetParser()
        return .noop
    }

    // MARK: Motions

    private func applyMotion(_ kind: MotionKind, find: (FindKind, Character)?) -> EngineResult {
        var motionCount = operatorKind != nil ? effectiveCount() : (count ?? 1)
        if kind == .gotoLine, let c = count, c == 0 {
            motionCount = 0
        }
        var cwAdjusted = kind
        if operatorKind == .change, (kind == .word || kind == .WORD) {
            let cls = buffer.isEmpty ? CharClass.whitespace : buffer.charClass(at: min(buffer.cursor, max(0, buffer.count - 1)))
            if cls == .keyword || cls == .other {
                cwAdjusted = kind == .WORD ? .WORDEnd : .wordEnd
            }
        }
        if operatorKind == nil, kind == .down || kind == .up {
            settleCurswant()
        }
        let resolved = MotionResolver.resolve(
            cwAdjusted,
            count: max(1, motionCount == 0 && kind == .gotoLine ? 1 : motionCount),
            buffer: buffer,
            layout: layout,
            find: find,
            searchPattern: searchPattern,
            searchForward: searchForward,
            operatorPending: operatorKind != nil
        )
        if kind == .gotoLine, count == 0 {
            let last = MotionResolver.resolve(
                .gotoLine,
                count: 0,
                buffer: buffer,
                layout: layout
            )
            return finishMotion(last, kind: kind, find: find, motionCount: 0)
        }
        return finishMotion(resolved, kind: cwAdjusted, find: find, motionCount: max(1, motionCount))
    }

    private func finishMotion(
        _ resolved: ResolvedMotion,
        kind: MotionKind,
        find: (FindKind, Character)?,
        motionCount: Int
    ) -> EngineResult {
        if let op = operatorKind {
            if resolved.failed {
                resetParser()
                return beepResult()
            }
            let spec = find.map { FindSpec(kind: $0.0, target: $0.1) }
            return applyOperator(op, motion: resolved, target: .motion(kind, count: motionCount, find: spec))
        }
        if resolved.failed {
            resetParser()
            return beepResult()
        }
        if mode.isVisual {
            buffer.cursor = buffer.clampedCursor(resolved.position, normalMode: true)
            updateCurswant(after: kind)
            resetParser()
            return .noop
        }
        switch kind {
        case .gotoLine, .fileStart, .search:
            recordJump(from: buffer.cursor)
        default:
            break
        }
        buffer.cursor = buffer.clampedCursor(resolved.position, normalMode: true)
        updateCurswant(after: kind)
        resetParser()
        return .noop
    }

    private func updateCurswant(after kind: MotionKind) {
        switch kind {
        case .up, .down:
            break
        case .screenLineEnd:
            buffer.curswant = .end
        default:
            resetCurswant()
        }
    }

    /// Horizontal motions and edits. The next `j` / `k` reads the column from the caret,
    /// after the host has laid out the edit, so wrapping is current.
    private func resetCurswant() {
        buffer.curswant = .fresh
    }

    /// First `j` / `k` after a reset: pin the caret's display column on its screen line.
    private func settleCurswant() {
        if buffer.curswant == .fresh {
            buffer.curswant = .column(screen.displayColumn(of: buffer.cursor))
        }
    }

    private func applyTextObject(_ object: TextObjectKind) -> EngineResult {
        guard let (range, style) = TextObjectResolver.resolve(object, buffer: buffer) else {
            resetParser()
            return beepResult()
        }
        if mode.isVisual {
            visualAnchor = range.lowerBound
            buffer.cursor = buffer.clampedCursor(buffer.graphemeStart(before: max(range.lowerBound + 1, range.upperBound)), normalMode: true)
            if style == .linewise { mode = .visualLine }
            resetParser()
            return .noop
        }
        guard let op = operatorKind else {
            resetParser()
            return beepResult()
        }
        return applyOperator(op, range: range, style: style, target: .textObject(object))
    }

    private func applyLinewiseOperator(_ op: OperatorKind) -> EngineResult {
        let n = effectiveCount()
        let line = buffer.lineIndex(containing: buffer.cursor)
        let end = min(buffer.lastLine, line + n - 1)
        let range = buffer.linesRange(from: line, through: end)
        return applyOperator(op, range: range, style: .linewise, target: .line)
    }

    private func applyNamedCommand(motion: MotionKind? = nil, linewise: Bool = false, op: OperatorKind) -> EngineResult {
        operatorKind = op
        operatorCount = count
        if linewise {
            return applyLinewiseOperator(op)
        }
        if let motion {
            return applyMotion(motion, find: nil)
        }
        resetParser()
        return beepResult()
    }

    private func applyOperatorToVisual(_ op: OperatorKind) -> EngineResult {
        guard let range = visualSelection, !range.isEmpty || op == .indent || op == .unindent else {
            mode = .normal
            resetParser()
            return beepResult()
        }
        let style: RangeStyle = mode == .visualLine ? .linewise : .characterwise
        let target: RepeatTarget
        // `>` and `<` shift whole lines from any visual mode, so `.` repeats them by line.
        if style == .linewise || op == .indent || op == .unindent {
            let l1 = buffer.lineIndex(containing: range.lowerBound)
            let l2 = buffer.lineIndex(containing: max(range.lowerBound, range.upperBound - 1))
            target = .visualLines(abs(l2 - l1) + 1)
        } else {
            // The replay counts characters, not UTF-16 units.
            target = .characterCount(max(1, buffer.graphemes(in: range).count))
        }
        return applyOperator(op, range: range, style: style, target: target)
    }

    private func applyOperator(
        _ op: OperatorKind,
        motion: ResolvedMotion,
        target: RepeatTarget
    ) -> EngineResult {
        guard let (range, style) = OperatorRange.compute(from: buffer.cursor, motion: motion, buffer: buffer) else {
            resetParser()
            return beepResult()
        }
        return applyOperator(op, range: range, style: style, target: target)
    }

    private func applyOperator(
        _ op: OperatorKind,
        range: Range<Int>,
        style: RangeStyle,
        target: RepeatTarget
    ) -> EngineResult {
        let n = effectiveCount()
        switch op {
        case .yank:
            yank(range, style: style)
            if style == .linewise {
                let line = buffer.lineIndex(containing: range.lowerBound)
                buffer.cursor = buffer.firstNonBlank(onLine: line)
            }
            resetParser()
            mode = .normal
            return .noop
        case .delete, .change:
            beginTransaction()
            let deleted = buffer.substring(range)
            yank(range, style: style, deleting: true)
            if style == .linewise {
                buffer.removeAnchors(in: range)
            }
            if style == .linewise, op == .change {
                // `cc` empties the lines but keeps one to type on.
                let keepsNewline = range.upperBound > range.lowerBound && buffer.character(at: range.upperBound - 1) == "\n"
                replace(range.lowerBound..<(range.upperBound - (keepsNewline ? 1 : 0)), with: "")
                buffer.cursor = range.lowerBound
            } else if style == .linewise {
                let removed = buffer.linewiseDeletion(range)
                replace(removed, with: "")
                let landing = buffer.clampedCursor(removed.lowerBound, normalMode: true)
                buffer.cursor = buffer.firstNonBlank(onLine: buffer.lineIndex(containing: landing))
            } else {
                replace(range, with: "")
                buffer.cursor = buffer.clampedCursor(range.lowerBound, normalMode: op == .delete)
            }
            resetCurswant()
            if op == .change {
                lastRepeatable = .operate(.change, count: n, target: target, inserted: nil)
                enterInsertMode(.change)
                _ = deleted
                return EngineResult(didChangeText: true, beep: false, actions: [])
            }
            commitTransaction()
            lastRepeatable = .operate(.delete, count: n, target: target, inserted: nil)
            mode = .normal
            resetParser()
            return EngineResult(didChangeText: true, beep: false, actions: [])
        case .indent, .unindent:
            beginTransaction()
            indent(range: range, direction: op == .indent ? 1 : -1)
            commitTransaction()
            lastRepeatable = .operate(op, count: n, target: target, inserted: nil)
            mode = .normal
            resetParser()
            return EngineResult(didChangeText: true, beep: false, actions: [])
        }
    }

    private func yank(_ range: Range<Int>, style: RangeStyle, deleting: Bool = false) {
        var text = buffer.substring(range)
        if style == .linewise, !text.hasSuffix("\n") {
            text += "\n"
        }
        let transfer: DirectoryTransfer = deleting ? .move : .copy
        let anchors = buffer.anchors(in: range).map { anchor -> Anchor in
            var copy = anchor
            copy.offset -= range.lowerBound
            if case .directoryEntry(let path, let isDir, _) = copy.kind {
                copy.kind = .directoryEntry(sourcePath: path, isDirectory: isDir, transfer: transfer)
            }
            return copy
        }
        let register = Register(text: text, style: style, anchors: anchors)
        storeYank(register)
    }

    private func storeYank(_ register: Register) {
        switch pendingRegister {
        case .clipboard:
            clipboard.text = register.text
            unnamed = register
            registers.unnamed = register
        case .blackHole:
            break
        case .named, .numbered, .smallDelete, .lastInsert, .lastSearch, .lastCommand:
            registers.write(register, to: pendingRegister)
            unnamed = registers.unnamed
        case .unnamed:
            unnamed = register
            registers.unnamed = register
            if register.style == .linewise || register.text.contains("\n") {
                registers.shiftNumbered(register)
                unnamed = registers.unnamed
            } else {
                registers.smallDelete = register
            }
        }
    }

    private func recordJump(from offset: Int) {
        if jumpBack.last != offset {
            jumpBack.append(offset)
        }
        if jumpBack.count > 100 { jumpBack.removeFirst() }
        jumpForward.removeAll()
    }

    private func jumpList(older: Bool) -> EngineResult {
        if older {
            guard let pos = jumpBack.popLast() else { return beepResult() }
            jumpForward.append(buffer.cursor)
            buffer.cursor = buffer.clampedCursor(pos, normalMode: mode != .insert)
        } else {
            guard let pos = jumpForward.popLast() else { return beepResult() }
            jumpBack.append(buffer.cursor)
            buffer.cursor = buffer.clampedCursor(pos, normalMode: mode != .insert)
        }
        resetCurswant()
        return .noop
    }

    // MARK: Insert

    private func beginInsert(_ kind: InsertKind) -> EngineResult {
        if mode.isVisual {
            resetParser()
            return beepResult()
        }
        insertCount = effectiveCount()
        prepareInsertPosition(kind)
        resetCurswant()
        lastRepeatable = .insert(kind: kind, text: "", count: insertCount)
        enterInsertMode(kind)
        resetParser()
        return EngineResult(didChangeText: kind == .o || kind == .O, beep: false, actions: [])
    }

    private func prepareInsertPosition(_ kind: InsertKind) {
        switch kind {
        case .i, .change, .s:
            break
        case .a:
            if !buffer.isEmpty {
                let line = buffer.lineIndex(containing: buffer.cursor)
                if buffer.cursor < buffer.lineEnd(at: line) {
                    buffer.cursor = buffer.graphemeSpan(containing: buffer.cursor).upperBound
                }
            }
        case .I:
            let line = buffer.lineIndex(containing: buffer.cursor)
            buffer.cursor = buffer.firstNonBlank(onLine: line)
        case .A:
            let line = buffer.lineIndex(containing: buffer.cursor)
            buffer.cursor = buffer.lineEnd(at: line)
        case .o:
            beginTransaction()
            let line = buffer.lineIndex(containing: buffer.cursor)
            let insertAt = buffer.lineFullRange(at: line).upperBound
            replace(insertAt..<insertAt, with: "\n")
            buffer.cursor = buffer.line(line + 1).start
        case .O:
            beginTransaction()
            let insertAt = buffer.bufferLine(containing: buffer.cursor).start
            replace(insertAt..<insertAt, with: "\n")
            buffer.cursor = insertAt
        }
    }

    private func enterInsertMode(_ kind: InsertKind) {
        insertKind = kind
        if groupDepth == 0 {
            beginTransaction()
        }
        insertBaseline = buffer.text
        insertBaselineCursor = buffer.cursor
        insertStarted = true
        mode = .insert
        count = nil
        operatorKind = nil
        operatorCount = nil
        pendingG = false
        pendingQuote = false
        pendingFind = nil
        pendingTextObjectInner = nil
    }

    private func handleInsert(_ event: KeyEvent) -> EngineResult {
        switch event.key {
        case .escape:
            return finishInsert()
        case .enter:
            replace(buffer.cursor..<buffer.cursor, with: "\n")
            buffer.cursor += 1
            resetCurswant()
            return EngineResult(didChangeText: true, beep: false, actions: [])
        case .backspace:
            if buffer.cursor == 0 { return beepResult() }
            let start = buffer.graphemeStart(before: buffer.cursor)
            replace(start..<buffer.cursor, with: "")
            buffer.cursor = start
            resetCurswant()
            return EngineResult(didChangeText: true, beep: false, actions: [])
        case .delete:
            if buffer.cursor >= buffer.count { return beepResult() }
            let end = buffer.graphemeSpan(containing: buffer.cursor).upperBound
            replace(buffer.cursor..<end, with: "")
            resetCurswant()
            return EngineResult(didChangeText: true, beep: false, actions: [])
        case .tab:
            let tab = String(repeating: " ", count: max(1, shiftWidth))
            replace(buffer.cursor..<buffer.cursor, with: tab)
            buffer.cursor += buffer.measure(tab)
            resetCurswant()
            return EngineResult(didChangeText: true, beep: false, actions: [])
        case .left:
            // Arrows stay on the buffer line, like vim's default `whichwrap`.
            if buffer.cursor > buffer.bufferLine(containing: buffer.cursor).start {
                buffer.cursor = buffer.graphemeStart(before: buffer.cursor)
            }
            resetCurswant()
            return .noop
        case .right:
            if buffer.cursor < buffer.bufferLine(containing: buffer.cursor).contentEnd {
                buffer.cursor = buffer.graphemeSpan(containing: buffer.cursor).upperBound
            }
            resetCurswant()
            return .noop
        case .up, .down:
            settleCurswant()
            let resolved = MotionResolver.resolve(
                event.key == .up ? .up : .down,
                count: 1,
                buffer: buffer,
                layout: layout,
                insert: true
            )
            if !resolved.failed {
                buffer.cursor = resolved.position
            }
            return .noop
        case .character(let ch):
            return insertText(String(ch))
        case .text(let text):
            return insertText(text)
        case .ctrl:
            return beepResult()
        }
    }

    private func insertText(_ text: String) -> EngineResult {
        let text = LineIndex.normalizingNewlines(text)
        if text.isEmpty { return .noop }
        replace(buffer.cursor..<buffer.cursor, with: text)
        buffer.cursor += buffer.measure(text)
        resetCurswant()
        return EngineResult(didChangeText: true, beep: false, actions: [])
    }

    private func finishInsert() -> EngineResult {
        let inserted = insertedTextSinceBaseline()
        if insertCount > 1, !inserted.isEmpty {
            let extra = String(repeating: inserted, count: insertCount - 1)
            replace(buffer.cursor..<buffer.cursor, with: extra)
            buffer.cursor += buffer.measure(extra)
        }
        switch lastRepeatable {
        case .insert(let kind, _, let count):
            lastRepeatable = .insert(kind: kind, text: inserted, count: count)
        case .operate(let op, let count, let target, _):
            lastRepeatable = .operate(op, count: count, target: target, inserted: inserted)
        default:
            lastRepeatable = .insert(kind: insertKind, text: inserted, count: insertCount)
        }
        insertStarted = false
        mode = .normal
        operatorKind = nil
        operatorCount = nil
        count = nil
        if !groupForward.isEmpty, buffer.cursor == buffer.count, buffer.lines.endsWithNewline {
            // The edit left the caret on the empty text after a final newline, which
            // is not a line in normal mode. One more newline makes it one, so
            // `o<Esc>` and `A<CR><Esc>` keep the line they made.
            let at = buffer.count
            replace(at..<at, with: "\n")
            buffer.cursor = at
        }
        if buffer.cursor > buffer.bufferLine(containing: buffer.cursor).start {
            buffer.cursor = buffer.graphemeStart(before: buffer.cursor)
        }
        buffer.clampCursor(normalMode: true)
        resetCurswant()
        commitTransaction()
        if !inserted.isEmpty {
            registers.lastInsert = Register(text: inserted, style: .characterwise)
        }
        let actions: [HostAction] = formatTablesOnInsertLeave
            ? [.formatTables(startLine: nil, endLine: nil, quiet: true)]
            : []
        return EngineResult(didChangeText: inserted.count > 0, beep: false, actions: actions)
    }

    private func insertedTextSinceBaseline() -> String {
        // Net text that appeared at the original insert cursor.
        let old = insertBaseline.utf16
        let new = buffer.text.utf16
        if old.elementsEqual(new) { return "" }
        let start = min(insertBaselineCursor, old.count, new.count)
        let tail = old.count - start
        if new.count - tail >= start,
           new.prefix(start).elementsEqual(old.prefix(start)),
           new.suffix(tail).elementsEqual(old.suffix(tail)) {
            return buffer.substring(start..<(new.count - tail))
        }
        // Fallback: characters currently between original cursor and now.
        let a = min(insertBaselineCursor, buffer.cursor)
        let b = max(insertBaselineCursor, buffer.cursor)
        return buffer.substring(a..<b)
    }

    // MARK: Commands

    private func commandDeleteChars(count: Int, enterInsert: Bool) -> EngineResult {
        if buffer.isEmpty {
            if enterInsert {
                lastRepeatable = .insert(kind: .s, text: "", count: 1)
                enterInsertMode(.s)
                return .noop
            }
            return beepResult()
        }
        beginTransaction()
        let line = buffer.lineIndex(containing: buffer.cursor)
        let endLimit = buffer.lineEnd(at: line)
        let end = buffer.endOfGraphemes(from: buffer.cursor, count: count, limit: endLimit)
        let range = buffer.cursor..<max(buffer.cursor, end)
        if range.isEmpty {
            abortTransaction()
            if enterInsert {
                enterInsertMode(.s)
                return .noop
            }
            return beepResult()
        }
        yank(range, style: .characterwise, deleting: true)
        replace(range, with: "")
        buffer.cursor = buffer.clampedCursor(range.lowerBound, normalMode: !enterInsert)
        resetCurswant()
        if enterInsert {
            lastRepeatable = .operate(.change, count: count, target: .characterCount(count), inserted: nil)
            enterInsertMode(.s)
        } else {
            commitTransaction()
            lastRepeatable = .operate(.delete, count: count, target: .characterCount(count), inserted: nil)
        }
        resetParser()
        return EngineResult(didChangeText: true, beep: false, actions: [])
    }

    private func handleReplaceChar(_ event: KeyEvent) -> EngineResult {
        mode = .normal
        let replacementChar: Character?
        switch event.key {
        case .character(let ch): replacementChar = ch
        case .text(let text): replacementChar = text.first
        default: replacementChar = nil
        }
        guard let ch = replacementChar, ch != "\n" else {
            if event.key == .escape { return .noop }
            return beepResult()
        }
        if buffer.isEmpty { return beepResult() }
        let n = effectiveCount()
        beginTransaction()
        let line = buffer.lineIndex(containing: buffer.cursor)
        let endLimit = buffer.lineEnd(at: line)
        let end = buffer.endOfGraphemes(from: buffer.cursor, count: n, limit: endLimit)
        guard buffer.cursor < end else {
            abortTransaction()
            return beepResult()
        }
        let replaced = buffer.graphemes(in: buffer.cursor..<end).count
        let replacement = String(repeating: String(ch), count: replaced)
        let start = buffer.cursor
        replace(start..<end, with: replacement)
        let lastStart = start + (replaced - 1) * String(ch).utf16.count
        buffer.cursor = buffer.clampedCursor(lastStart, normalMode: true)
        resetCurswant()
        lastRepeatable = .replace(count: n, ch)
        resetParser()
        commitTransaction()
        return EngineResult(didChangeText: true, beep: false, actions: [])
    }

    private func toggleCase(count n: Int) -> EngineResult {
        if mode.isVisual, let range = visualSelection {
            beginTransaction()
            toggleCase(in: range)
            commitTransaction()
            mode = .normal
            resetCurswant()
            lastRepeatable = .toggleCase(count: range.count)
            resetParser()
            return EngineResult(didChangeText: true, beep: false, actions: [])
        }
        if buffer.isEmpty { return beepResult() }
        beginTransaction()
        let endLimit = buffer.bufferLine(containing: buffer.cursor).contentEnd
        var end = buffer.cursor
        for _ in 0..<n where end < endLimit {
            end = buffer.graphemeSpan(containing: end).upperBound
        }
        toggleCase(in: buffer.cursor..<end)
        buffer.cursor = buffer.clampedCursor(end, normalMode: true)
        resetCurswant()
        lastRepeatable = .toggleCase(count: n)
        resetParser()
        commitTransaction()
        return EngineResult(didChangeText: true, beep: false, actions: [])
    }

    private func toggleCase(in range: Range<Int>) {
        guard !range.isEmpty else { return }
        var out = ""
        out.reserveCapacity(range.count)
        for (_, ch) in buffer.graphemes(in: range.clamped(to: 0..<buffer.count)) {
            if ch.isUppercase {
                out += ch.lowercased()
            } else if ch.isLowercase {
                out += ch.uppercased()
            } else {
                out.append(ch)
            }
        }
        replace(range, with: out)
    }

    private func joinLines(count n: Int) -> EngineResult {
        let line = buffer.lineIndex(containing: buffer.cursor)
        let last = min(buffer.lastLine, line + max(1, n - 1))
        if last == line { return beepResult() }
        beginTransaction()
        for _ in line..<last {
            let current = buffer.lineIndex(containing: buffer.cursor)
            if current + 1 > buffer.lastLine { break }
            let end = buffer.lineEnd(at: current)
            let nextContent = buffer.lineContentRange(at: current + 1)
            var next = nextContent.lowerBound
            while next < nextContent.upperBound {
                let ch = buffer.character(at: next)
                if ch == " " || ch == "\t" { next += 1; continue }
                break
            }
            let joinSpace: String
            if end == buffer.line(current).start || nextContent.isEmpty {
                joinSpace = ""
            } else {
                joinSpace = " "
            }
            let deleteTo = next
            replace(end..<deleteTo, with: joinSpace)
            buffer.cursor = end
        }
        buffer.clampCursor(normalMode: true)
        resetCurswant()
        lastRepeatable = .join(count: n)
        resetParser()
        commitTransaction()
        return EngineResult(didChangeText: true, beep: false, actions: [])
    }

    private func put(after: Bool, count n: Int) -> EngineResult {
        let source: Register
        switch pendingRegister {
        case .clipboard:
            let text = LineIndex.normalizingNewlines(clipboard.text)
            source = Register(text: text, style: text.hasSuffix("\n") ? .linewise : .characterwise)
        case .unnamed:
            source = unnamed
        default:
            source = registers.read(pendingRegister)
        }
        if source.text.isEmpty {
            resetParser()
            return beepResult()
        }
        beginTransaction()
        let payload = String(repeating: source.text, count: max(1, n))
        if source.style == .linewise {
            let target = buffer.line(min(buffer.lineIndex(containing: buffer.cursor), buffer.lastLine))
            var text = payload
            if !text.hasSuffix("\n") { text += "\n" }
            let insertAt = after ? target.end : target.start
            // After a last line with no newline, the lines go in as `"\n" + lines`
            // minus their final newline, so the buffer still ends without one.
            // An empty last line keeps its newline, since empty text after a final
            // newline is no line at all.
            let shift = after && !target.hasNewline ? 1 : 0
            if shift == 1 { text = "\n" + (text == "\n" || text.hasSuffix("\n\n") ? text : String(text.dropLast())) }
            replace(insertAt..<insertAt, with: text)
            installPutAnchors(source, at: insertAt + shift)
            buffer.cursor = buffer.firstNonBlank(onLine: min(buffer.lineIndex(containing: insertAt + shift), buffer.lastLine))
        } else {
            var at = buffer.cursor
            if after, !buffer.isEmpty {
                if at < buffer.bufferLine(containing: at).contentEnd {
                    at = buffer.graphemeSpan(containing: at).upperBound
                }
            }
            replace(at..<at, with: payload)
            installPutAnchors(source, at: at)
            let pastPut = at + buffer.measure(payload)
            buffer.cursor = buffer.clampedCursor(pastPut > at ? buffer.graphemeStart(before: pastPut) : at, normalMode: true)
        }
        resetCurswant()
        lastRepeatable = .put(after: after, count: n)
        resetParser()
        mode = .normal
        commitTransaction()
        return EngineResult(didChangeText: true, beep: false, actions: [])
    }

    private func installPutAnchors(_ source: Register, at insertAt: Int) {
        for anchor in source.anchors {
            var installed = anchor
            installed.offset += insertAt
            buffer.addAnchor(installed)
        }
    }

    private func indent(range: Range<Int>, direction: Int) {
        let startLine = min(buffer.lineIndex(containing: range.lowerBound), buffer.lastLine)
        let lastUnit = range.isEmpty ? range.lowerBound : range.upperBound - 1
        let endLine = max(startLine, min(buffer.lineIndex(containing: lastUnit), buffer.lastLine))
        indent(lines: startLine...endLine, direction: direction)
    }

    /// Shift whole buffer lines. Like vim, `>` leaves empty lines alone.
    private func indent(lines: ClosedRange<Int>, direction: Int) {
        let startLine = lines.lowerBound
        let pad = String(repeating: " ", count: max(1, shiftWidth))
        if direction > 0 {
            for line in lines.reversed() where !buffer.isBlankLine(line) {
                let at = buffer.line(line).start
                replace(at..<at, with: pad)
            }
        } else {
            for line in lines.reversed() {
                let content = buffer.lineContentRange(at: line)
                var removed = 0
                var i = content.lowerBound
                while i < content.upperBound, removed < shiftWidth {
                    let ch = buffer.character(at: i)
                    if ch == " " {
                        removed += 1
                        i += 1
                    } else if ch == "\t" {
                        removed = shiftWidth
                        i += 1
                    } else {
                        break
                    }
                }
                if i > content.lowerBound {
                    replace(content.lowerBound..<i, with: "")
                }
            }
        }
        buffer.cursor = buffer.firstNonBlank(onLine: startLine)
        resetCurswant()
    }

    // MARK: Repeat / undo

    private func repeatLast() -> EngineResult {
        guard let command = lastRepeatable else { return beepResult() }
        resetParser()
        switch command {
        case .insert(let kind, let text, let n):
            _ = beginInsert(kind)
            if !text.isEmpty {
                let repeated = String(repeating: text, count: max(1, n))
                replace(buffer.cursor..<buffer.cursor, with: repeated)
                buffer.cursor += buffer.measure(repeated)
            }
            return finishInsertKeepingRepeatable(command)
        case .operate(let op, let n, let target, let inserted):
            operatorKind = op
            operatorCount = n
            count = nil
            let result: EngineResult
            switch target {
            case .line:
                count = n
                result = applyLinewiseOperator(op)
            case .motion(let kind, let mc, let find):
                count = mc
                result = applyMotion(kind, find: find.map { ($0.kind, $0.target) })
            case .textObject(let obj):
                result = applyTextObject(obj)
            case .characterCount(let c):
                result = commandDeleteChars(count: c, enterInsert: op == .change)
            case .visualLines(let lines):
                count = lines
                result = applyLinewiseOperator(op)
            }
            if op == .change, mode == .insert {
                if let inserted, !inserted.isEmpty {
                    replace(buffer.cursor..<buffer.cursor, with: inserted)
                    buffer.cursor += buffer.measure(inserted)
                }
                _ = finishInsertKeepingRepeatable(command)
            }
            lastRepeatable = command
            if mode != .insert { resetParser() }
            return result
        case .replace(let n, let ch):
            count = n
            mode = .replaceChar
            return handleReplaceChar(KeyEvent(.character(ch)))
        case .toggleCase(let n):
            return toggleCase(count: n)
        case .join(let n):
            return joinLines(count: n)
        case .put(let after, let n):
            return put(after: after, count: n)
        }
    }

    private func finishInsertKeepingRepeatable(_ command: Repeatable) -> EngineResult {
        let result = finishInsert()
        lastRepeatable = command
        return result
    }

    private func beginTransaction() {
        if groupDepth == 0 {
            groupForward.removeAll(keepingCapacity: true)
            groupInverse.removeAll(keepingCapacity: true)
            groupCursorBefore = buffer.cursor
            redoStack.removeAll()
            groupBareLastLineStart = buffer.isEmpty || buffer.lines.endsWithNewline ? nil : buffer.line(buffer.lastLine).start
        }
        groupDepth += 1
    }

    /// Empty text after a final newline is not a line, so emptying a last line that
    /// has no newline (`x` on the `b` of `"a\nb"`) would delete the line itself.
    /// Vim keeps it as an empty line; one more newline does the same here. A newline
    /// added after the line's content (a formatter's final newline) leaves its start
    /// where it was, so it does not trigger this.
    private func keepEmptiedLastLine() {
        guard let start = groupBareLastLineStart, start == buffer.count, buffer.lines.endsWithNewline else { return }
        let onLine = buffer.cursor >= start || groupCursorBefore >= start
        replace(start..<start, with: "\n")
        if onLine { buffer.cursor = start }
    }

    private func commitTransaction() {
        guard groupDepth > 0 else { return }
        if groupDepth == 1 { keepEmptiedLastLine() }
        groupBareLastLineStart = groupDepth == 1 ? nil : groupBareLastLineStart
        groupDepth -= 1
        if groupDepth == 0 {
            if !groupForward.isEmpty {
                let stamp = nextStamp
                nextStamp += 1
                currentStamp = stamp
                undoStack.append(UndoEntry(
                    forward: groupForward,
                    inverse: groupInverse,
                    cursorBefore: groupCursorBefore,
                    cursorAfter: buffer.cursor,
                    stamp: stamp
                ))
                isModified = currentStamp != savedStamp
            }
            groupForward.removeAll(keepingCapacity: true)
            groupInverse.removeAll(keepingCapacity: true)
        }
    }

    private func abortTransaction() {
        groupDepth = 0
        groupBareLastLineStart = nil
        groupForward.removeAll(keepingCapacity: true)
        groupInverse.removeAll(keepingCapacity: true)
    }

    private func undo() -> EngineResult {
        guard let entry = undoStack.popLast() else { return beepResult() }
        redoStack.append(entry)
        applyHistory(entry.inverse.reversed(), cursor: entry.cursorBefore)
        currentStamp = undoStack.last?.stamp ?? 0
        isModified = currentStamp != savedStamp
        mode = .normal
        resetParser()
        return EngineResult(didChangeText: true, beep: false, actions: [])
    }

    private func redo() -> EngineResult {
        guard let entry = redoStack.popLast() else { return beepResult() }
        undoStack.append(entry)
        applyHistory(entry.forward, cursor: entry.cursorAfter)
        currentStamp = entry.stamp
        isModified = currentStamp != savedStamp
        mode = .normal
        resetParser()
        return EngineResult(didChangeText: true, beep: false, actions: [])
    }

    private func applyHistory<S: Sequence>(_ edits: S, cursor: Int) where S.Element == TextEdit {
        for edit in edits {
            let lower = min(max(0, edit.range.lowerBound), buffer.count)
            let upper = min(max(lower, edit.range.upperBound), buffer.count)
            buffer.replace(lower..<upper, with: edit.replacement)
            strokeEdits.append(TextEdit(range: lower..<upper, replacement: edit.replacement))
        }
        buffer.cursor = buffer.clampedCursor(cursor, normalMode: true)
        resetCurswant()
    }

    // MARK: Search / ex

    private func handleSearchCollect(_ event: KeyEvent) -> EngineResult {
        switch event.key {
        case .escape:
            mode = .normal
            commandLine = ""
            return .noop
        case .enter:
            let pattern = String(commandLine.dropFirst())
            mode = .normal
            commandLine = ""
            if !pattern.isEmpty {
                searchPattern = pattern
            }
            if searchPattern.isEmpty { return beepResult() }
            return applyMotion(.search(forward: true), find: nil)
        case .backspace:
            if commandLine.count <= 1 {
                mode = .normal
                commandLine = ""
                return .noop
            }
            commandLine.removeLast()
            return .noop
        case .character(let ch):
            commandLine.append(ch)
            return .noop
        case .text(let text):
            commandLine.append(text)
            return .noop
        default:
            return .noop
        }
    }

    private func handleCommandLine(_ event: KeyEvent) -> EngineResult {
        switch event.key {
        case .escape:
            mode = .normal
            commandLine = ""
            return .noop
        case .backspace:
            if commandLine.count <= 1 {
                mode = .normal
                commandLine = ""
                return .noop
            }
            commandLine.removeLast()
            return .noop
        case .enter:
            let cmd = String(commandLine.dropFirst()).trimASCIISpaces()
            mode = .normal
            commandLine = ""
            if !cmd.isEmpty { commandHistory.append(cmd) }
            return executeEx(cmd)
        case .left:
            return .noop
        case .right:
            return .noop
        case .up:
            guard !commandHistory.isEmpty else { return .noop }
            historyCursor = max(0, historyCursor - 1)
            if historyCursor >= commandHistory.count { historyCursor = commandHistory.count - 1 }
            commandLine = ":" + commandHistory[historyCursor]
            return .noop
        case .down:
            if historyCursor + 1 < commandHistory.count {
                historyCursor += 1
                commandLine = ":" + commandHistory[historyCursor]
            }
            return .noop
        case .character(let ch):
            commandLine.append(ch)
            return .noop
        case .text(let text):
            commandLine.append(text)
            return .noop
        default:
            return .noop
        }
    }

    // MARK: Buffer writes

    private func replace(_ range: Range<Int>, with new: String) {
        let lower = min(max(0, range.lowerBound), buffer.count)
        let upper = min(max(lower, range.upperBound), buffer.count)
        let span = lower..<upper
        let old = buffer.substring(span)
        let edit = TextEdit(range: span, replacement: new)
        if groupDepth > 0 {
            let width = buffer.measure(new)
            groupForward.append(edit)
            groupInverse.append(TextEdit(range: lower..<(lower + width), replacement: old))
            if let start = groupBareLastLineStart {
                if span.isEmpty ? start >= lower : start >= upper {
                    groupBareLastLineStart = start + width - span.count
                } else if start > lower {
                    groupBareLastLineStart = lower
                }
            }
        }
        buffer.replace(span, with: new)
        strokeEdits.append(edit)
        lastEdit = edit
        isModified = true
        if groupDepth == 0 {
            currentStamp = nextStamp
            nextStamp += 1
        }
    }

    private var parserIsIdle: Bool {
        count == nil && operatorKind == nil && !pendingG && !pendingQuote && pendingLeader == nil
            && !pendingMarkSet && pendingMarkJump == nil
    }

    private func setMark(_ ch: Character) -> EngineResult {
        guard ch.isLetter || ch == "<" || ch == ">" else { return beepResult() }
        let kind = AnchorKind.mark(String(ch))
        buffer.removeAnchors { $0.kind == kind }
        buffer.addAnchor(Anchor(
            id: AnchorID(raw: UInt64(ch.asciiValue ?? 1)),
            offset: buffer.cursor,
            gravity: .right,
            kind: kind
        ))
        return .noop
    }

    private func jumpToMark(_ ch: Character) -> EngineResult {
        guard let anchor = buffer.anchors.first(where: {
            if case .mark(let name) = $0.kind { return name == String(ch) }
            return false
        }) else { return beepResult() }
        recordJump(from: buffer.cursor)
        buffer.cursor = buffer.clampedCursor(anchor.offset, normalMode: true)
        resetCurswant()
        return .noop
    }

    private func executeEx(_ cmd: String) -> EngineResult {
        let parsed = Ex.parse(cmd)
        if parsed.name.lowercased() == "tableformat" {
            return tableFormat(parsed)
        }
        switch parsed.name {
        case "w":
            return EngineResult(didChangeText: false, beep: false, actions: [.write])
        case "q":
            if parsed.bang || !isModified {
                return EngineResult(didChangeText: false, beep: false, actions: [.quit])
            }
            statusMessage = "No write since last change"
            return beepResult()
        case "wq", "x":
            return EngineResult(didChangeText: false, beep: false, actions: [.writeQuit])
        case "e":
            let name = parsed.args.isEmpty ? "edit" : "edit:\(parsed.args)"
            return EngineResult(didChangeText: false, beep: false, actions: [.command(name)])
        case "sp":
            return EngineResult(didChangeText: false, beep: false, actions: [.command("split")])
        case "vs":
            return EngineResult(didChangeText: false, beep: false, actions: [.command("vsplit")])
        case "set":
            return applySet(parsed.args)
        case "theme":
            if parsed.args.isEmpty {
                return EngineResult(didChangeText: false, beep: false, actions: [.toggleTheme])
            }
            guard let choice = ThemeChoice.parse(parsed.args) else {
                statusMessage = "theme must be light, dark, or system"
                return beepResult()
            }
            return EngineResult(didChangeText: false, beep: false, actions: [.setTheme(choice)])
        case "s":
            return substitute(parsed)
        case "" where parsed.rangeStart != nil && parsed.args.isEmpty:
            // `:N`, `:$`, `:'a`: a buffer line, wherever it wraps on screen.
            let last = buffer.lastLine
            let current = buffer.lineIndex(containing: buffer.cursor)
            let target = resolveAddress(parsed.rangeEnd ?? parsed.rangeStart, current: current, last: last)
            recordJump(from: buffer.cursor)
            buffer.cursor = buffer.clampedCursor(buffer.firstNonBlank(onLine: target), normalMode: true)
            resetCurswant()
            return .noop
        default:
            statusMessage = "Not an editor command"
            return beepResult()
        }
    }

    private func tableFormat(_ parsed: ParsedEx) -> EngineResult {
        if !parsed.args.isEmpty {
            statusMessage = "Not an editor command"
            return beepResult()
        }
        let last = buffer.lastLine
        let current = buffer.lineIndex(containing: buffer.cursor)
        let action: HostAction
        if parsed.rangeStart == nil && parsed.rangeEnd == nil {
            action = .formatTables(startLine: nil, endLine: nil, quiet: false)
        } else if parsed.rangeStart == .all || parsed.rangeEnd == .all {
            action = .formatTables(startLine: 0, endLine: last, quiet: false)
        } else {
            let start = resolveAddress(parsed.rangeStart, current: current, last: last)
            let end = resolveAddress(parsed.rangeEnd ?? parsed.rangeStart, current: current, last: last)
            action = .formatTables(startLine: min(start, end), endLine: max(start, end), quiet: false)
        }
        return EngineResult(didChangeText: false, beep: false, actions: [action])
    }

    private func applySet(_ args: String) -> EngineResult {
        let parts = args.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == "shiftwidth" || parts[0] == "sw", let width = Int(parts[1]) else {
            statusMessage = "Not an editor command"
            return beepResult()
        }
        shiftWidth = max(1, width)
        return .noop
    }

    private func substitute(_ parsed: ParsedEx) -> EngineResult {
        guard let parts = Searcher.substituteParts(parsed.args), !parts.pattern.isEmpty else {
            statusMessage = "Not an editor command"
            return beepResult()
        }
        let last = buffer.lastLine
        let current = buffer.lineIndex(containing: buffer.cursor)
        let startLine: Int
        let endLine: Int
        if parsed.rangeStart == .all {
            startLine = 0
            endLine = last
        } else {
            startLine = resolveAddress(parsed.rangeStart, current: current, last: last)
            endLine = resolveAddress(parsed.rangeEnd ?? parsed.rangeStart, current: current, last: last)
        }
        let lower = min(startLine, endLine)
        let upper = max(startLine, endLine)
        beginTransaction()
        // UTF-16 distance from the end of the last changed text to the end of the
        // buffer. Edits above it (which may add lines) leave this distance alone.
        var lastChangedFromEnd: Int?
        for line in stride(from: upper, through: lower, by: -1) {
            let content = buffer.lineContentRange(at: line)
            let text = buffer.substring(content)
            let updated = replaceInLine(text, pattern: parts.pattern, with: LineIndex.normalizingNewlines(parts.replacement), global: parts.global)
            if updated != text {
                replace(content, with: updated)
                if lastChangedFromEnd == nil {
                    lastChangedFromEnd = buffer.count - (content.lowerBound + buffer.measure(updated))
                }
            }
        }
        guard let lastChangedFromEnd else {
            abortTransaction()
            return beepResult()
        }
        // Like vim, the caret goes to the last line changed.
        let landing = buffer.lineIndex(containing: buffer.count - lastChangedFromEnd)
        buffer.cursor = buffer.firstNonBlank(onLine: min(landing, buffer.lastLine))
        resetCurswant()
        commitTransaction()
        return EngineResult(didChangeText: true, beep: false, actions: [])
    }

    private func resolveAddress(_ address: ParsedEx.Address?, current: Int, last: Int) -> Int {
        switch address {
        case .none, .current?: return current
        case .last, .all: return last
        case .number(let n): return min(max(0, n - 1), last)
        case .mark(let name):
            if let anchor = buffer.anchors.first(where: {
                if case .mark(let mark) = $0.kind { return mark == String(name) }
                return false
            }) {
                return min(buffer.lineIndex(containing: anchor.offset), last)
            }
            return current
        }
    }

    private func replaceInLine(_ text: String, pattern: String, with replacement: String, global: Bool) -> String {
        let units = Array(text.utf16)
        var out: [UInt16] = []
        var index = 0
        for hit in Searcher.literalMatches(in: text, pattern: pattern) where hit.lowerBound >= index {
            out.append(contentsOf: units[index..<hit.lowerBound])
            out.append(contentsOf: replacement.utf16)
            index = hit.upperBound
            if !global { break }
        }
        out.append(contentsOf: units[index...])
        return String(decoding: out, as: UTF16.self)
    }

    private func beepResult() -> EngineResult {
        EngineResult(didChangeText: false, beep: true, actions: [])
    }
}
