import QuillText

/// GitHub-flavored tables as plain-text blocks. Vim motions keep using the
/// characters in the buffer. `blocks` describes how to paint a table.
/// `plan` rewrites those characters so the pipes line up.
public enum ColumnAlign: Equatable, Sendable {
    case left
    case center
    case right
}

public struct TableColumn: Equatable, Sendable {
    public var align: ColumnAlign
    public var leftColon: Bool
    public var rightColon: Bool

    public init(align: ColumnAlign, leftColon: Bool, rightColon: Bool) {
        self.align = align
        self.leftColon = leftColon
        self.rightColon = rightColon
    }
}

public struct TableCell: Equatable, Sendable {
    /// Characters between the surrounding pipes, including the spaces the author typed.
    public var raw: Range<Int>
    /// Trimmed text inside `raw`. Empty when the cell is blank.
    public var text: Range<Int>
    public var trimmed: String
    public var align: ColumnAlign
    /// UTF-16 offset of the pipe before this cell, when the row has one.
    public var precedingPipe: Int?
    /// Extra mono cells before the trimmed text. The styler kerns `precedingPipe`,
    /// or indents the row when this is the first cell and there is no pipe.
    public var leadingPad: Int
    /// Extra mono cells after `raw`. The styler kerns the last character of `raw`.
    public var trailingPad: Int

    public init(
        raw: Range<Int>,
        text: Range<Int>,
        trimmed: String,
        align: ColumnAlign,
        precedingPipe: Int?,
        leadingPad: Int,
        trailingPad: Int
    ) {
        self.raw = raw
        self.text = text
        self.trimmed = trimmed
        self.align = align
        self.precedingPipe = precedingPipe
        self.leadingPad = leadingPad
        self.trailingPad = trailingPad
    }
}

public struct TableRow: Equatable, Sendable {
    public enum Role: Equatable, Sendable {
        case header
        case separator
        case body
    }

    public var role: Role
    /// Line content, excluding the newline and a trailing CR.
    public var range: Range<Int>
    public var cells: [TableCell]
    public var pipes: [Range<Int>]

    public init(role: Role, range: Range<Int>, cells: [TableCell], pipes: [Range<Int>]) {
        self.role = role
        self.range = range
        self.cells = cells
        self.pipes = pipes
    }
}

public struct TableBlock: Equatable, Sendable {
    public var range: Range<Int>
    /// Whitespace before the header's leading pipe, applied to every formatted row.
    public var indent: String
    public var columns: [TableColumn]
    public var rows: [TableRow]
    /// Display cells in the widest row once every cell is padded to its column.
    public var alignedColumns: Int

    public init(
        range: Range<Int>,
        indent: String,
        columns: [TableColumn],
        rows: [TableRow],
        alignedColumns: Int = 0
    ) {
        self.range = range
        self.indent = indent
        self.columns = columns
        self.rows = rows
        self.alignedColumns = alignedColumns
    }

    /// Padding a cell is drawn as extra advance on one character, and a line
    /// cannot break inside a character. A padded table wider than the column
    /// would draw past it, so it is shown as typed and its rows wrap instead.
    public func alignsWithin(columns available: Int) -> Bool {
        alignedColumns <= available
    }
}

public struct TableRewrite: Equatable, Sendable {
    public var range: Range<Int>
    public var replacement: String

    public init(range: Range<Int>, replacement: String) {
        self.range = range
        self.replacement = replacement
    }
}

public struct TablePlan: Equatable, Sendable {
    /// A table matched the scope. False when the cursor or line range is not in one.
    public var matched: Bool
    public var rewrites: [TableRewrite]
    /// `cursor` mapped through `rewrites`, in the coordinate space after the edits.
    public var cursor: Int

    public init(matched: Bool, rewrites: [TableRewrite], cursor: Int) {
        self.matched = matched
        self.rewrites = rewrites
        self.cursor = cursor
    }
}

public enum TableScope: Equatable, Sendable {
    /// The table containing `cursor` passed to `plan`.
    case cursor
    /// Inclusive 0-based line indexes.
    case lines(ClosedRange<Int>)
    case document
}

public enum MarkdownTables {
    public static func blocks(in text: String) -> [TableBlock] {
        let lines = LineSplit.lines(in: text)
        guard !lines.isEmpty else { return [] }
        let blocked = blockMask(lines: lines, text: text)
        return blocks(lines: lines, from: 0, through: lines.count - 1) { blocked[$0] }
    }

    /// Tables that intersect `utf16`, including rows outside that range.
    /// Column widths come from the whole table, so a visible body row still
    /// lines up with a header that is scrolled off screen.
    public static func blocks(in text: String, overlapping utf16: Range<Int>) -> [TableBlock] {
        let lines = LineSplit.lines(in: text)
        guard !lines.isEmpty, !utf16.isEmpty, let lastLine = lines.last, lastLine.end > 0 else { return [] }
        let blocked = blockMask(lines: lines, text: text)
        let span = neighborhoodLines(in: lines, overlapping: utf16, isBlocked: { blocked[$0] })
        guard !span.isEmpty else { return [] }
        return blocks(lines: lines, from: span.lowerBound, through: span.upperBound - 1) { blocked[$0] }
    }

    /// Inclusive line indexes of the pipe-run around `utf16`. Rows that just
    /// dropped out of a table stay in this window so a restyle can clear them.
    static func neighborhoodLines(
        in lines: [LineSplit.Line],
        overlapping utf16: Range<Int>,
        isBlocked: (Int) -> Bool
    ) -> Range<Int> {
        guard !lines.isEmpty, !utf16.isEmpty, let lastLine = lines.last, lastLine.end > 0 else { return 0..<0 }
        let lower = min(max(0, utf16.lowerBound), lastLine.end - 1)
        let upper = min(max(lower, utf16.upperBound - 1), lastLine.end - 1)
        let first = LineSplit.lineIndex(containing: lower, lines: lines)
        let last = LineSplit.lineIndex(containing: upper, lines: lines)
        return expandedLines(lines: lines, first: first, last: last, isBlocked: isBlocked)
    }

    /// `from` and `through` are inclusive line indexes. The caller expands them
    /// to the whole table; this only parses that window.
    static func blocks(
        lines: [LineSplit.Line],
        from start: Int,
        through end: Int,
        isBlocked: (Int) -> Bool
    ) -> [TableBlock] {
        guard !lines.isEmpty, start <= end, start >= 0, end < lines.count else { return [] }
        var blocks: [TableBlock] = []
        var index = start
        while index <= end {
            if isBlocked(index) {
                index += 1
                continue
            }
            guard index + 1 <= end, !isBlocked(index + 1),
                  let header = parseRow(lines[index]), header.specs == nil,
                  let delimiter = parseRow(lines[index + 1]), let specs = delimiter.specs, !specs.isEmpty
            else {
                index += 1
                continue
            }
            var rawRows: [(RawRow, TableRow.Role)] = [(header, .header), (delimiter, .separator)]
            var next = index + 2
            while next <= end, !isBlocked(next), !blank(lines[next]), let row = parseRow(lines[next]) {
                rawRows.append((row, .body))
                next += 1
            }
            blocks.append(makeBlock(rawRows, specs: specs, lines: lines, first: index, last: next - 1))
            index = next
        }
        return blocks
    }

    /// Inclusive table lines around `[first, last]`. A line joins the window when
    /// it contains a pipe, is not blank, and is not inside a fence or frontmatter.
    static func expandedLines(
        lines: [LineSplit.Line],
        first: Int,
        last: Int,
        isBlocked: (Int) -> Bool
    ) -> Range<Int> {
        guard lines.indices.contains(first), lines.indices.contains(last), first <= last else { return 0..<0 }
        var start = first
        while start > 0, tableLine(lines, start - 1, isBlocked: isBlocked) { start -= 1 }
        var end = last
        while end + 1 < lines.count, tableLine(lines, end + 1, isBlocked: isBlocked) { end += 1 }
        return start..<(end + 1)
    }

    static func tableLine(_ lines: [LineSplit.Line], _ index: Int, isBlocked: (Int) -> Bool) -> Bool {
        guard lines.indices.contains(index) else { return false }
        if lines[index].isBlank || isBlocked(index) { return false }
        return parseRow(lines[index]) != nil
    }

    public static func plan(in text: String, scope: TableScope, cursor: Int) -> TablePlan {
        let found = blocks(in: text)
        let lines = LineSplit.lines(in: text)
        let chosen = select(found, scope: scope, cursor: cursor, lines: lines)
        guard !chosen.isEmpty else {
            return TablePlan(matched: false, rewrites: [], cursor: cursor)
        }
        var rewrites: [TableRewrite] = []
        for block in chosen {
            let widths = formatWidths(block)
            for row in block.rows {
                let replacement = formattedLine(row, indent: block.indent, columns: block.columns, widths: widths)
                if slice(text, row.range) != replacement {
                    rewrites.append(TableRewrite(range: row.range, replacement: replacement))
                }
            }
        }
        return TablePlan(
            matched: true,
            rewrites: rewrites,
            cursor: mapCursor(cursor, text: text, rewrites: rewrites)
        )
    }
}

private struct RawCell {
    var raw: Range<Int>
    var text: Range<Int>
    var trimmed: String
    var precedingPipe: Int?
    var columns: Int
    var leadingColumns: Int
    var trailingColumns: Int
}

private struct RawRow {
    var indent: String
    var range: Range<Int>
    var cells: [RawCell]
    var pipes: [Range<Int>]
    var specs: [TableColumn]?
    var columns: Int
}

private func blockMask(lines: [LineSplit.Line], text: String) -> [Bool] {
    var entering = BlockState()
    if text.hasPrefix("---") { entering.inFrontmatter = true }
    var blocked: [Bool] = []
    blocked.reserveCapacity(lines.count)
    for line in lines {
        blocked.append(entering.inFence || entering.inFrontmatter)
        let (_, exit) = Scanner.scan(line: line, entering: entering)
        entering = exit
    }
    return blocked
}

private func blank(_ line: LineSplit.Line) -> Bool {
    var text = line.text
    if text.hasSuffix("\r") { text.removeLast() }
    return LineSplit.blank(text)
}

private func select(
    _ blocks: [TableBlock],
    scope: TableScope,
    cursor: Int,
    lines: [LineSplit.Line]
) -> [TableBlock] {
    switch scope {
    case .document:
        return blocks
    case .cursor:
        return blocks.filter { $0.range.contains(cursor) }
    case .lines(let span):
        return blocks.filter { block in
            guard let first = block.rows.first, let last = block.rows.last else { return false }
            let start = LineSplit.lineIndex(containing: first.range.lowerBound, lines: lines)
            let end = LineSplit.lineIndex(containing: last.range.lowerBound, lines: lines)
            return start <= span.upperBound && end >= span.lowerBound
        }
    }
}

private func makeBlock(
    _ rows: [(RawRow, TableRow.Role)],
    specs: [TableColumn],
    lines: [LineSplit.Line],
    first: Int,
    last: Int
) -> TableBlock {
    var columns = specs
    let maxCells = rows.map { $0.0.cells.count }.max() ?? specs.count
    while columns.count < maxCells {
        columns.append(TableColumn(align: .left, leftColon: false, rightColon: false))
    }
    // Trimmed display width, so `|a|` and `| a |` share a content column and
    // the live kern can add the same gutters `:TableFormat` writes as spaces.
    var widths = [Int](repeating: 0, count: max(columns.count, 1))
    for (raw, _) in rows {
        for (index, cell) in raw.cells.enumerated() where index < widths.count {
            widths[index] = max(widths[index], DisplayWidth.columns(of: cell.trimmed))
        }
    }
    var pads: [[(Int, Int)]] = []
    pads.reserveCapacity(rows.count)
    var visual = [Int](repeating: 0, count: max(columns.count, 1))
    for (raw, _) in rows {
        var rowPads: [(Int, Int)] = []
        rowPads.reserveCapacity(raw.cells.count)
        for (index, cell) in raw.cells.enumerated() {
            let align = index < columns.count ? columns[index].align : ColumnAlign.left
            let pad = visualPads(cell, width: index < widths.count ? widths[index] : 0, align: align)
            rowPads.append(pad)
            if index < visual.count {
                visual[index] = max(visual[index], cell.columns + pad.0 + pad.1)
            }
        }
        pads.append(rowPads)
    }
    var tableRows: [TableRow] = []
    tableRows.reserveCapacity(rows.count)
    var alignedColumns = 0
    for (rowIndex, (raw, role)) in rows.enumerated() {
        var padded = raw.columns
        var cells: [TableCell] = []
        cells.reserveCapacity(raw.cells.count)
        for (index, cell) in raw.cells.enumerated() {
            let align = index < columns.count ? columns[index].align : ColumnAlign.left
            var leading = pads[rowIndex][index].0
            var trailing = pads[rowIndex][index].1
            let extra = index < visual.count
                ? max(0, visual[index] - cell.columns - leading - trailing)
                : 0
            switch align {
            case .left:
                trailing += extra
            case .right:
                leading += extra
            case .center:
                leading += extra / 2
                trailing += extra - extra / 2
            }
            if cell.columns == 0 {
                leading += trailing
                trailing = 0
            }
            padded += leading + trailing
            cells.append(TableCell(
                raw: cell.raw,
                text: cell.text,
                trimmed: cell.trimmed,
                align: align,
                precedingPipe: cell.precedingPipe,
                leadingPad: leading,
                trailingPad: trailing
            ))
        }
        alignedColumns = max(alignedColumns, padded)
        tableRows.append(TableRow(role: role, range: raw.range, cells: cells, pipes: raw.pipes))
    }
    return TableBlock(
        range: lines[first].start..<lines[last].end,
        indent: rows.first?.0.indent ?? "",
        columns: columns,
        rows: tableRows,
        alignedColumns: alignedColumns
    )
}

private func visualPads(_ cell: RawCell, width: Int, align: ColumnAlign) -> (Int, Int) {
    let trimmed = DisplayWidth.columns(of: cell.trimmed)
    let deficit = max(0, width - trimmed)
    var wantLead = 1
    var wantTrail = 1
    switch align {
    case .left:
        wantTrail += deficit
    case .right:
        wantLead += deficit
    case .center:
        let left = deficit / 2
        wantLead += left
        wantTrail += deficit - left
    }
    if trimmed == 0 {
        let extra = max(0, wantLead + wantTrail - cell.columns)
        return cell.columns == 0 ? (extra, 0) : (0, extra)
    }
    let leading = max(0, wantLead - cell.leadingColumns)
    let trailing = max(0, wantTrail - cell.trailingColumns)
    return (leading, trailing)
}

private func formatWidths(_ block: TableBlock) -> [Int] {
    let count = max(block.columns.count, block.rows.map(\.cells.count).max() ?? 0)
    var widths = [Int](repeating: 3, count: max(count, 1))
    for row in block.rows where row.role != .separator {
        for (index, cell) in row.cells.enumerated() where index < widths.count {
            widths[index] = max(widths[index], DisplayWidth.columns(of: cell.trimmed))
        }
    }
    for index in widths.indices {
        let column = index < block.columns.count
            ? block.columns[index]
            : TableColumn(align: .left, leftColon: false, rightColon: false)
        let minRule = 1 + (column.leftColon ? 1 : 0) + (column.rightColon ? 1 : 0)
        widths[index] = max(widths[index], max(3, minRule))
    }
    return widths
}

private func formattedLine(_ row: TableRow, indent: String, columns: [TableColumn], widths: [Int]) -> String {
    let count = max(columns.count, row.cells.count, widths.count)
    var parts: [String] = []
    parts.reserveCapacity(count)
    for index in 0..<count {
        let column = index < columns.count
            ? columns[index]
            : TableColumn(align: .left, leftColon: false, rightColon: false)
        let width = index < widths.count ? widths[index] : 3
        if row.role == .separator {
            parts.append(rule(column, width: width))
        } else {
            let text = index < row.cells.count ? row.cells[index].trimmed : ""
            parts.append(pad(text, align: column.align, width: width))
        }
    }
    return indent + "| " + parts.joined(separator: " | ") + " |"
}

private func pad(_ text: String, align: ColumnAlign, width: Int) -> String {
    let gap = max(0, width - DisplayWidth.columns(of: text))
    switch align {
    case .left:
        return text + String(repeating: " ", count: gap)
    case .right:
        return String(repeating: " ", count: gap) + text
    case .center:
        let left = gap / 2
        return String(repeating: " ", count: left) + text + String(repeating: " ", count: gap - left)
    }
}

private func rule(_ column: TableColumn, width: Int) -> String {
    let size = max(width, 3)
    if column.leftColon && column.rightColon {
        return ":" + String(repeating: "-", count: size - 2) + ":"
    }
    if column.rightColon {
        return String(repeating: "-", count: size - 1) + ":"
    }
    if column.leftColon {
        return ":" + String(repeating: "-", count: size - 1)
    }
    return String(repeating: "-", count: size)
}

private func mapCursor(_ cursor: Int, text: String, rewrites: [TableRewrite]) -> Int {
    let ordered = rewrites.sorted { $0.range.lowerBound < $1.range.lowerBound }
    var shift = 0
    for rewrite in ordered {
        let oldLength = rewrite.range.upperBound - rewrite.range.lowerBound
        let newLength = rewrite.replacement.utf16.count
        if rewrite.range.upperBound <= cursor {
            shift += newLength - oldLength
            continue
        }
        if rewrite.range.lowerBound > cursor { break }
        let old = slice(text, rewrite.range)
        let local = cursor - rewrite.range.lowerBound
        return rewrite.range.lowerBound + shift + mapLocal(old: old, new: rewrite.replacement, local: local)
    }
    return max(0, cursor + shift)
}

private func mapLocal(old: String, new: String, local: Int) -> Int {
    let limit = max(0, new.utf16.count)
    guard let oldRow = parseContent(old, lineStart: 0), let newRow = parseContent(new, lineStart: 0) else {
        return min(max(0, local), limit)
    }
    for (index, pipe) in oldRow.pipes.enumerated() where pipe.contains(local) {
        if index < newRow.pipes.count {
            return min(newRow.pipes[index].lowerBound, limit)
        }
    }
    for (index, cell) in oldRow.cells.enumerated() where cell.raw.contains(local) || local == cell.raw.lowerBound {
        guard index < newRow.cells.count else { break }
        let destination = newRow.cells[index]
        if local <= cell.text.lowerBound {
            return min(destination.text.lowerBound, limit)
        }
        if cell.text.isEmpty || local >= cell.text.upperBound {
            return min(destination.text.upperBound, limit)
        }
        let delta = local - cell.text.lowerBound
        let room = destination.text.upperBound - destination.text.lowerBound
        return min(destination.text.lowerBound + min(delta, room), limit)
    }
    return min(max(0, local), limit)
}

private func parseRow(_ line: LineSplit.Line) -> RawRow? {
    var source = line.text
    if source.hasSuffix("\r") { source.removeLast() }
    return parseContent(source, lineStart: line.start)
}

private func parseContent(_ source: String, lineStart: Int) -> RawRow? {
    if source.isEmpty { return nil }
    if Scanner.listMarkerUTF16(source) != nil { return nil }
    var index = source.startIndex
    var units = 0
    var indentColumns = 0
    while index < source.endIndex {
        let character = source[index]
        if character == " " {
            indentColumns += 1
        } else if character == "\t" {
            indentColumns += 4
        } else {
            break
        }
        units += character.utf16.count
        index = source.index(after: index)
    }
    if indentColumns >= 4 { return nil }
    guard index < source.endIndex, source[index] != ">" else { return nil }

    let pipeFirst = source[index] == "|"
    let indent = pipeFirst ? String(source[..<index]) : ""
    var cursor = pipeFirst ? index : source.startIndex
    var utf = pipeFirst ? units : 0
    var pipes: [Range<Int>] = []
    var drafts: [(raw: Range<Int>, pipe: Int?)] = []
    var sawPipe = false
    var inCode = false
    var cellStart = utf
    var preceding: Int? = nil

    if pipeFirst {
        pipes.append((lineStart + utf)..<(lineStart + utf + 1))
        preceding = utf
        sawPipe = true
        utf += source[cursor].utf16.count
        cursor = source.index(after: cursor)
        cellStart = utf
    }

    while cursor < source.endIndex {
        let character = source[cursor]
        if character == "\\",
           let next = source.index(cursor, offsetBy: 1, limitedBy: source.endIndex),
           next < source.endIndex {
            utf += character.utf16.count + source[next].utf16.count
            cursor = source.index(after: next)
            continue
        }
        if character == "`" {
            inCode.toggle()
            utf += character.utf16.count
            cursor = source.index(after: cursor)
            continue
        }
        if character == "|", !inCode {
            drafts.append((cellStart..<utf, preceding))
            pipes.append((lineStart + utf)..<(lineStart + utf + character.utf16.count))
            preceding = utf
            sawPipe = true
            utf += character.utf16.count
            cursor = source.index(after: cursor)
            cellStart = utf
            continue
        }
        utf += character.utf16.count
        cursor = source.index(after: cursor)
    }
    drafts.append((cellStart..<utf, preceding))
    guard sawPipe else { return nil }
    if let last = drafts.last, whitespaceOnly(slice(source, last.raw)), last.pipe != nil {
        drafts.removeLast()
    }
    guard !drafts.isEmpty else { return nil }

    let cells = drafts.map { makeCell(source: source, rawLocal: $0.raw, pipe: $0.pipe, lineStart: lineStart) }
    let specs = columnSpecs(cells.map(\.trimmed))
    let contentEnd = lineStart + source.utf16.count
    return RawRow(
        indent: indent,
        range: lineStart..<contentEnd,
        cells: cells,
        pipes: pipes,
        specs: specs,
        columns: DisplayWidth.columns(of: source)
    )
}

private func whitespaceOnly(_ text: String) -> Bool {
    text.allSatisfy { $0 == " " || $0 == "\t" }
}

private func trimSpaces(_ text: String) -> String {
    var start = text.startIndex
    var end = text.endIndex
    while start < end, text[start] == " " || text[start] == "\t" {
        start = text.index(after: start)
    }
    while end > start {
        let previous = text.index(before: end)
        if text[previous] != " " && text[previous] != "\t" { break }
        end = previous
    }
    return String(text[start..<end])
}

private func makeCell(source: String, rawLocal: Range<Int>, pipe: Int?, lineStart: Int) -> RawCell {
    let rawString = slice(source, rawLocal)
    let trimmed = trimSpaces(rawString)
    let leading = rawString.prefix(while: { $0 == " " || $0 == "\t" }).utf16.count
    let trailing = rawString.reversed().prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + $1.utf16.count }
    let textLocal: Range<Int>
    if trimmed.isEmpty {
        textLocal = rawLocal.upperBound..<rawLocal.upperBound
    } else {
        textLocal = (rawLocal.lowerBound + leading)..<(rawLocal.upperBound - trailing)
    }
    let leadingText = String(rawString.prefix(while: { $0 == " " || $0 == "\t" }))
    let trailingText: String
    if trimmed.isEmpty {
        trailingText = ""
    } else {
        trailingText = String(rawString.reversed().prefix(while: { $0 == " " || $0 == "\t" }).reversed())
    }
    return RawCell(
        raw: shift(rawLocal, by: lineStart),
        text: shift(textLocal, by: lineStart),
        trimmed: trimmed,
        precedingPipe: pipe.map { lineStart + $0 },
        columns: DisplayWidth.columns(of: rawString),
        leadingColumns: DisplayWidth.columns(of: leadingText),
        trailingColumns: DisplayWidth.columns(of: trailingText)
    )
}

private func columnSpecs(_ cells: [String]) -> [TableColumn]? {
    guard !cells.isEmpty else { return nil }
    var specs: [TableColumn] = []
    specs.reserveCapacity(cells.count)
    for cell in cells {
        guard let spec = columnSpec(cell) else { return nil }
        specs.append(spec)
    }
    return specs
}

private func columnSpec(_ trimmed: String) -> TableColumn? {
    guard trimmed.contains("-") else { return nil }
    var dashes = 0
    var left = false
    var right = false
    for (offset, character) in trimmed.enumerated() {
        if offset == 0, character == ":" {
            left = true
            continue
        }
        if character == "-" {
            dashes += 1
            continue
        }
        if character == ":", dashes > 0, offset == trimmed.count - 1 {
            right = true
            continue
        }
        return nil
    }
    guard dashes >= 1, trimmed.hasSuffix(":") == right else { return nil }
    let align: ColumnAlign
    if left && right {
        align = .center
    } else if right {
        align = .right
    } else {
        align = .left
    }
    return TableColumn(align: align, leftColon: left, rightColon: right)
}

private func shift(_ range: Range<Int>, by base: Int) -> Range<Int> {
    (base + range.lowerBound)..<(base + range.upperBound)
}

private func slice(_ text: String, _ range: Range<Int>) -> String {
    let units = Array(text.utf16)
    guard range.lowerBound >= 0 else { return "" }
    let end = min(max(range.lowerBound, range.upperBound), units.count)
    let start = min(range.lowerBound, end)
    return String(decoding: units[start..<end], as: UTF16.self)
}
