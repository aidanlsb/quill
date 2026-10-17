/// A from-scratch vim engine: parse count, then operator, then motion or text object.
/// Motions and text objects return ranges; operators act on those ranges so they compose.
/// Every change is recorded as a replayable command for `.` and grouped undo.
public final class Engine: @unchecked Sendable {
    public var buffer: TextBuffer
    public var mode: Mode = .normal
    public var layout: any TextLayout
    public var clipboard: any Clipboard
    public var shiftWidth: Int = 2
    /// When true, Enter in normal mode asks the host to open the current line
    /// (directory listings) instead of moving down.
    public var openOnEnter: Bool = false
    /// Leader key in normal mode. Space by default; configurable by the host.
    public var leaderKey: Character = " "
    /// Sequence → action after the leader. Host loads this from config.
    public var leaderBindings: [String: HostAction] = [
        "sf": .findFiles,
        "sg": .liveGrep,
    ]
    public private(set) var isModified: Bool = false
    public private(set) var statusMessage: String = ""
    public private(set) var commandLine: String = ""
    public private(set) var lastEdit: TextEdit?

    var unnamed = Register.empty
    var visualAnchor: Int = 0

    var count: Int?
    var operatorKind: OperatorKind?
    var operatorCount: Int?
    var pendingG = false
    var pendingQuote = false
    var pendingRegister: RegisterName = .unnamed
    var pendingFind: FindKind?
    var pendingTextObjectInner: Bool?
    var pendingLeader: String?

    var lastFind: (FindKind, Character)?
    var searchPattern: String = ""
    var searchForward: Bool = true

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
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
        layout: (any TextLayout)? = nil
    ) {
        self.buffer = TextBuffer(text: text, cursor: cursor)
        self.clipboard = clipboard ?? MemoryClipboard()
        self.layout = layout ?? LogicalLineLayout.shared
        self.buffer.preferredColumn = self.buffer.column(of: self.buffer.cursor)
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
        let end = min(b + 1, buffer.count)
        return a..<max(a, end)
    }

    public func load(text: String, cursor: Int = 0) {
        buffer = TextBuffer(text: text, cursor: cursor)
        buffer.preferredColumn = buffer.column(of: buffer.cursor)
        mode = .normal
        isModified = false
        undoStack = []
        redoStack = []
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
        isModified = false
    }

    public func moveCursor(to offset: Int) {
        buffer.cursor = buffer.clampedCursor(offset, normalMode: mode != .insert)
        buffer.preferredColumn = buffer.column(of: buffer.cursor)
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
        lastEdit = nil
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
            return beepResult()
        case .character(let ch):
            return handleNormalCharacter(ch)
        }
    }

    private func handleNormalCharacter(_ ch: Character) -> EngineResult {
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
            if ch == "d", operatorKind == nil, !mode.isVisual {
                resetParser()
                return EngineResult(didChangeText: false, beep: false, actions: [.goToDefinition])
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
                return applyMotion(.lineStart, find: nil)
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
            return applyMotion(.lineEnd, find: nil)
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
            return commandDeleteChars(count: effectiveCount(), enterInsert: false)
        case "s":
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
            return applyNamedCommand(motion: .lineEnd, op: .delete)
        case "C":
            return applyNamedCommand(motion: .lineEnd, op: .change)
        case "Y":
            return applyNamedCommand(linewise: true, op: .yank)
        case ":":
            if mode.isVisual { return beepResult() }
            mode = .commandLine
            commandLine = ":"
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
        guard case .character(let ch) = event.key, event.key != .escape else {
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
                layout: layout,
                operatorPending: operatorKind != nil
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
            updatePreferredColumn(after: kind)
            resetParser()
            return .noop
        }
        buffer.cursor = buffer.clampedCursor(resolved.position, normalMode: true)
        updatePreferredColumn(after: kind)
        resetParser()
        return .noop
    }

    private func updatePreferredColumn(after kind: MotionKind) {
        switch kind {
        case .up, .down:
            break
        case .lineEnd:
            buffer.preferredColumn = Int.max / 4
        default:
            buffer.preferredColumn = buffer.column(of: buffer.cursor)
        }
    }

    private func applyTextObject(_ object: TextObjectKind) -> EngineResult {
        guard let (range, style) = TextObjectResolver.resolve(object, buffer: buffer) else {
            resetParser()
            return beepResult()
        }
        if mode.isVisual {
            visualAnchor = range.lowerBound
            buffer.cursor = buffer.clampedCursor(max(range.lowerBound, range.upperBound - 1), normalMode: true)
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
        let end = min(buffer.lineCount - 1, line + n - 1)
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
        let lineCount: Int
        if style == .linewise {
            let l1 = buffer.lineIndex(containing: range.lowerBound)
            let l2 = buffer.lineIndex(containing: max(range.lowerBound, range.upperBound - 1))
            lineCount = abs(l2 - l1) + 1
        } else {
            lineCount = range.count
        }
        let target: RepeatTarget = style == .linewise
            ? .visualLines(lineCount)
            : .characterCount(max(1, range.count))
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
            beginUndo()
            let deleted = buffer.substring(range)
            yank(range, style: style)
            replace(range, with: "")
            buffer.cursor = buffer.clampedCursor(range.lowerBound, normalMode: op == .delete)
            buffer.preferredColumn = buffer.column(of: buffer.cursor)
            if op == .change {
                lastRepeatable = .operate(.change, count: n, target: target, inserted: nil)
                enterInsertMode(.change)
                _ = deleted
                return EngineResult(didChangeText: true, beep: false, actions: [])
            }
            lastRepeatable = .operate(.delete, count: n, target: target, inserted: nil)
            mode = .normal
            resetParser()
            return EngineResult(didChangeText: true, beep: false, actions: [])
        case .indent, .unindent:
            beginUndo()
            indent(range: range, direction: op == .indent ? 1 : -1)
            lastRepeatable = .operate(op, count: n, target: target, inserted: nil)
            mode = .normal
            resetParser()
            return EngineResult(didChangeText: true, beep: false, actions: [])
        }
    }

    private func yank(_ range: Range<Int>, style: RangeStyle) {
        var text = buffer.substring(range)
        if style == .linewise, !text.hasSuffix("\n"), !text.isEmpty {
            text += "\n"
        }
        let register = Register(text: text, style: style)
        unnamed = register
        if pendingRegister == .clipboard {
            clipboard.text = text
        }
    }

    // MARK: Insert

    private func beginInsert(_ kind: InsertKind) -> EngineResult {
        if mode.isVisual {
            resetParser()
            return beepResult()
        }
        insertCount = effectiveCount()
        prepareInsertPosition(kind)
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
                let end = buffer.lineEnd(at: line)
                if buffer.cursor < end {
                    buffer.cursor += 1
                }
            }
        case .I:
            let line = buffer.lineIndex(containing: buffer.cursor)
            buffer.cursor = buffer.firstNonBlank(onLine: line)
        case .A:
            let line = buffer.lineIndex(containing: buffer.cursor)
            buffer.cursor = buffer.lineEnd(at: line)
        case .o:
            beginUndo()
            let line = buffer.lineIndex(containing: buffer.cursor)
            let insertAt = buffer.lineFullRange(at: line).upperBound
            replace(insertAt..<insertAt, with: "\n")
            buffer.cursor = insertAt + (insertAt == buffer.count && !buffer.text.hasSuffix("\n") ? 0 : 0)
            // After inserting newline at end of line content...
            let newLine = buffer.lineIndex(containing: min(insertAt, max(0, buffer.count - 1)))
            // Place cursor on the new line.
            if insertAt <= buffer.count {
                buffer.cursor = min(insertAt + (buffer.substring(insertAt..<min(insertAt + 1, buffer.count)) == "\n" ? 0 : 0), buffer.count)
            }
            // Simpler: go to start of the line after the original.
            let targetLine = min(line + 1, buffer.lineCount - 1)
            buffer.cursor = buffer.lineStarts[targetLine]
            insertStarted = true
        case .O:
            beginUndo()
            let line = buffer.lineIndex(containing: buffer.cursor)
            let insertAt = buffer.lineStarts[line]
            replace(insertAt..<insertAt, with: "\n")
            buffer.cursor = insertAt
            insertStarted = true
        }
    }

    private func enterInsertMode(_ kind: InsertKind) {
        insertKind = kind
        if !insertStarted {
            beginUndo()
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
            return EngineResult(didChangeText: true, beep: false, actions: [])
        case .backspace:
            if buffer.cursor == 0 { return beepResult() }
            replace((buffer.cursor - 1)..<buffer.cursor, with: "")
            buffer.cursor -= 1
            return EngineResult(didChangeText: true, beep: false, actions: [])
        case .delete:
            if buffer.cursor >= buffer.count { return beepResult() }
            replace(buffer.cursor..<(buffer.cursor + 1), with: "")
            return EngineResult(didChangeText: true, beep: false, actions: [])
        case .tab:
            let tab = String(repeating: " ", count: max(1, shiftWidth))
            replace(buffer.cursor..<buffer.cursor, with: tab)
            buffer.cursor += tab.count
            return EngineResult(didChangeText: true, beep: false, actions: [])
        case .left:
            buffer.cursor = max(0, buffer.cursor - 1)
            return .noop
        case .right:
            buffer.cursor = min(buffer.count, buffer.cursor + 1)
            return .noop
        case .up, .down:
            let delta = event.key == .up ? -1 : 1
            buffer.cursor = layout.position(
                from: buffer.cursor,
                displayLines: delta,
                preferredColumn: buffer.column(of: buffer.cursor),
                in: buffer
            )
            return .noop
        case .character(let ch):
            replace(buffer.cursor..<buffer.cursor, with: String(ch))
            buffer.cursor += 1
            return EngineResult(didChangeText: true, beep: false, actions: [])
        case .ctrl:
            return beepResult()
        }
    }

    private func finishInsert() -> EngineResult {
        let inserted = insertedTextSinceBaseline()
        if insertCount > 1, !inserted.isEmpty {
            let extra = String(repeating: inserted, count: insertCount - 1)
            replace(buffer.cursor..<buffer.cursor, with: extra)
            buffer.cursor += extra.count
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
        if buffer.cursor > 0 {
            let prev = buffer.cursor - 1
            let line = buffer.lineIndex(containing: buffer.cursor)
            if buffer.cursor > buffer.lineStarts[line] {
                buffer.cursor = prev
            }
        }
        buffer.clampCursor(normalMode: true)
        buffer.preferredColumn = buffer.column(of: buffer.cursor)
        if insertBaseline == buffer.text {
            // Nothing changed — drop the undo snapshot.
            if !undoStack.isEmpty { _ = undoStack.popLast() }
        }
        return EngineResult(didChangeText: inserted.count > 0, beep: false, actions: [])
    }

    private func insertedTextSinceBaseline() -> String {
        // Net text that appeared at the original insert cursor.
        if buffer.text == insertBaseline { return "" }
        let start = min(insertBaselineCursor, buffer.count)
        if buffer.text.hasPrefix(String(insertBaseline.prefix(start))),
           buffer.text.hasSuffix(String(insertBaseline.dropFirst(start))) {
            let end = buffer.count - (insertBaseline.count - start)
            if start <= end {
                return buffer.substring(start..<end)
            }
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
        beginUndo()
        let line = buffer.lineIndex(containing: buffer.cursor)
        let endLimit = buffer.lineEnd(at: line)
        let end = min(buffer.cursor + count, endLimit)
        let range = buffer.cursor..<max(buffer.cursor, end)
        if range.isEmpty {
            if enterInsert {
                enterInsertMode(.s)
                return .noop
            }
            return beepResult()
        }
        yank(range, style: .characterwise)
        replace(range, with: "")
        buffer.cursor = buffer.clampedCursor(range.lowerBound, normalMode: !enterInsert)
        if enterInsert {
            lastRepeatable = .operate(.change, count: count, target: .characterCount(count), inserted: nil)
            enterInsertMode(.s)
        } else {
            lastRepeatable = .operate(.delete, count: count, target: .characterCount(count), inserted: nil)
        }
        resetParser()
        return EngineResult(didChangeText: true, beep: false, actions: [])
    }

    private func handleReplaceChar(_ event: KeyEvent) -> EngineResult {
        mode = .normal
        guard case .character(let ch) = event.key, ch != "\n" else {
            if event.key == .escape { return .noop }
            return beepResult()
        }
        if buffer.isEmpty { return beepResult() }
        let n = effectiveCount()
        beginUndo()
        let line = buffer.lineIndex(containing: buffer.cursor)
        let endLimit = buffer.lineEnd(at: line)
        let end = min(buffer.cursor + n, endLimit)
        guard buffer.cursor < end else { return beepResult() }
        let replacement = String(repeating: String(ch), count: end - buffer.cursor)
        replace(buffer.cursor..<end, with: replacement)
        buffer.cursor = buffer.clampedCursor(end - 1, normalMode: true)
        lastRepeatable = .replace(count: n, ch)
        resetParser()
        return EngineResult(didChangeText: true, beep: false, actions: [])
    }

    private func toggleCase(count n: Int) -> EngineResult {
        if mode.isVisual, let range = visualSelection {
            beginUndo()
            toggleCase(in: range)
            mode = .normal
            lastRepeatable = .toggleCase(count: range.count)
            resetParser()
            return EngineResult(didChangeText: true, beep: false, actions: [])
        }
        if buffer.isEmpty { return beepResult() }
        beginUndo()
        let line = buffer.lineIndex(containing: buffer.cursor)
        let endLimit = buffer.lineEnd(at: line)
        let end = min(buffer.cursor + n, endLimit)
        toggleCase(in: buffer.cursor..<end)
        buffer.cursor = buffer.clampedCursor(min(end, endLimit - (endLimit > buffer.lineStarts[line] ? 1 : 0)), normalMode: true)
        if buffer.cursor < end, end < endLimit {
            buffer.cursor = end
            buffer.clampCursor(normalMode: true)
        }
        lastRepeatable = .toggleCase(count: n)
        resetParser()
        return EngineResult(didChangeText: true, beep: false, actions: [])
    }

    private func toggleCase(in range: Range<Int>) {
        guard !range.isEmpty else { return }
        var out = ""
        out.reserveCapacity(range.count)
        for off in range {
            if off >= buffer.count { break }
            let ch = buffer.character(at: off)
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
        let last = min(buffer.lineCount - 1, line + max(1, n - 1))
        if last == line { return beepResult() }
        beginUndo()
        for _ in line..<last {
            let current = buffer.lineIndex(containing: buffer.cursor)
            if current + 1 >= buffer.lineCount { break }
            let end = buffer.lineEnd(at: current)
            let nextStart = buffer.lineStarts[current + 1]
            let nextContent = buffer.lineContentRange(at: current + 1)
            var next = nextContent.lowerBound
            while next < nextContent.upperBound {
                let ch = buffer.character(at: next)
                if ch == " " || ch == "\t" { next += 1; continue }
                break
            }
            let joinSpace: String
            if end == buffer.lineStarts[current] || nextContent.isEmpty {
                joinSpace = ""
            } else {
                joinSpace = " "
            }
            let deleteTo = next
            replace(end..<deleteTo, with: joinSpace)
            buffer.cursor = end
        }
        buffer.clampCursor(normalMode: true)
        lastRepeatable = .join(count: n)
        resetParser()
        return EngineResult(didChangeText: true, beep: false, actions: [])
    }

    private func put(after: Bool, count n: Int) -> EngineResult {
        let source: Register
        if pendingRegister == .clipboard {
            source = Register(text: clipboard.text, style: clipboard.text.hasSuffix("\n") ? .linewise : .characterwise)
        } else {
            source = unnamed
        }
        if source.text.isEmpty {
            resetParser()
            return beepResult()
        }
        beginUndo()
        let payload = String(repeating: source.text, count: max(1, n))
        if source.style == .linewise {
            let line = buffer.lineIndex(containing: buffer.cursor)
            var insertAt: Int
            var text = payload
            if !text.hasSuffix("\n") { text += "\n" }
            if after {
                insertAt = buffer.lineFullRange(at: line).upperBound
                if insertAt == buffer.count, !buffer.text.hasSuffix("\n") {
                    text = "\n" + text
                }
            } else {
                insertAt = buffer.lineStarts[line]
            }
            replace(insertAt..<insertAt, with: text)
            let dest = after ? insertAt + (text.hasPrefix("\n") && insertAt == buffer.lineFullRange(at: line).upperBound ? 1 : 0) : insertAt
            buffer.cursor = buffer.firstNonBlank(onLine: buffer.lineIndex(containing: min(dest, max(0, buffer.count - 1))))
        } else {
            var at = buffer.cursor
            if after, !buffer.isEmpty {
                let line = buffer.lineIndex(containing: at)
                if at < buffer.lineEnd(at: line) {
                    at += 1
                }
            }
            replace(at..<at, with: payload)
            buffer.cursor = buffer.clampedCursor(at + payload.count - 1, normalMode: true)
        }
        lastRepeatable = .put(after: after, count: n)
        resetParser()
        mode = .normal
        return EngineResult(didChangeText: true, beep: false, actions: [])
    }

    private func indent(range: Range<Int>, direction: Int) {
        let startLine = buffer.lineIndex(containing: range.lowerBound)
        var endLine = buffer.lineIndex(containing: max(range.lowerBound, range.upperBound - (range.isEmpty ? 0 : 1)))
        if range.upperBound > range.lowerBound,
           buffer.column(of: range.upperBound) == 0,
           endLine > startLine {
            endLine -= 1
        }
        let pad = String(repeating: " ", count: max(1, shiftWidth))
        var offsetAdjust = 0
        for line in startLine...endLine {
            let start = buffer.lineStarts[line] + offsetAdjust
            // Recompute because earlier inserts shifted later lines; rebuild is in replace.
            let currentLine = startLine + (line - startLine)
            _ = currentLine
        }
        // Apply from last line to first so offsets stay valid... actually replace rebuilds lines.
        // Collect line starts first.
        let lines = startLine...endLine
        if direction > 0 {
            for line in lines.reversed() {
                let at = buffer.lineStarts[line]
                buffer.replace(at..<at, with: pad)
                offsetAdjust += pad.count
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
                    buffer.replace(content.lowerBound..<i, with: "")
                }
            }
        }
        lastEdit = TextEdit(range: range, replacement: "")
        isModified = true
        buffer.cursor = buffer.firstNonBlank(onLine: startLine)
        buffer.preferredColumn = buffer.column(of: buffer.cursor)
    }

    // MARK: Repeat / undo

    private func repeatLast() -> EngineResult {
        guard let command = lastRepeatable else { return beepResult() }
        resetParser()
        switch command {
        case .insert(let kind, let text, let n):
            _ = beginInsert(kind)
            if !text.isEmpty {
                replace(buffer.cursor..<buffer.cursor, with: String(repeating: text, count: max(1, n)))
                buffer.cursor += text.count * max(1, n)
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
            if op == .change, let inserted, !inserted.isEmpty, mode == .insert {
                replace(buffer.cursor..<buffer.cursor, with: inserted)
                buffer.cursor += inserted.count
                _ = finishInsertKeepingRepeatable(command)
            }
            lastRepeatable = command
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

    private struct Snapshot {
        var text: String
        var cursor: Int
    }

    private func beginUndo() {
        undoStack.append(Snapshot(text: buffer.text, cursor: buffer.cursor))
        redoStack.removeAll()
    }

    private func undo() -> EngineResult {
        guard let snap = undoStack.popLast() else { return beepResult() }
        redoStack.append(Snapshot(text: buffer.text, cursor: buffer.cursor))
        let old = buffer.text
        buffer = TextBuffer(text: snap.text, cursor: snap.cursor)
        isModified = true
        lastEdit = TextEdit(range: 0..<old.count, replacement: snap.text)
        mode = .normal
        resetParser()
        return EngineResult(didChangeText: true, beep: false, actions: [])
    }

    private func redo() -> EngineResult {
        guard let snap = redoStack.popLast() else { return beepResult() }
        undoStack.append(Snapshot(text: buffer.text, cursor: buffer.cursor))
        let old = buffer.text
        buffer = TextBuffer(text: snap.text, cursor: snap.cursor)
        isModified = true
        lastEdit = TextEdit(range: 0..<old.count, replacement: snap.text)
        mode = .normal
        resetParser()
        return EngineResult(didChangeText: true, beep: false, actions: [])
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
            switch cmd {
            case "w":
                return EngineResult(didChangeText: false, beep: false, actions: [.write])
            case "q":
                if isModified {
                    statusMessage = "No write since last change"
                    return beepResult()
                }
                return EngineResult(didChangeText: false, beep: false, actions: [.quit])
            case "wq", "x":
                return EngineResult(didChangeText: false, beep: false, actions: [.writeQuit])
            default:
                statusMessage = "Not an editor command"
                return beepResult()
            }
        case .character(let ch):
            commandLine.append(ch)
            return .noop
        default:
            return .noop
        }
    }

    // MARK: Buffer writes

    private func replace(_ range: Range<Int>, with new: String) {
        lastEdit = TextEdit(range: range, replacement: new)
        buffer.replace(range, with: new)
        isModified = true
    }

    private func beepResult() -> EngineResult {
        EngineResult(didChangeText: false, beep: true, actions: [])
    }
}
