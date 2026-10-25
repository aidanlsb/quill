import XCTest
@testable import QuillMarkdown

final class TableTests: XCTestCase {
    func testDetectsAlignmentsAndSkipsFences() {
        let text = """
        ---
        title: Note
        ---
        | L | C | R |
        | :--- | :---: | ---: |
        | a | b | c |

        A pipe | in prose.

        ```
        | L | C | R |
        | :--- | :---: | ---: |
        | a | b | c |
        ```

        - | no | list |
        | --- | --- |
        """
        let blocks = MarkdownTables.blocks(in: text)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].columns.map(\.align), [.left, .center, .right])
        XCTAssertEqual(blocks[0].columns.map(\.leftColon), [true, true, false])
        XCTAssertEqual(blocks[0].columns.map(\.rightColon), [false, true, true])
        XCTAssertEqual(blocks[0].rows.map(\.role), [.header, .separator, .body])
        XCTAssertEqual(blocks[0].rows[0].cells.map(\.trimmed), ["L", "C", "R"])
        XCTAssertEqual(blocks[0].rows[2].cells.map(\.trimmed), ["a", "b", "c"])
        let centered = apply(
            MarkdownTables.plan(in: "| a |\n| :---: |\n| b |\n", scope: .document, cursor: 0),
            to: "| a |\n| :---: |\n| b |\n"
        )
        XCTAssertEqual(centered, "|  a  |\n| :-: |\n|  b  |\n")
    }

    func testEscapedAndCodeSpanPipesStayInTheCell() {
        let escaped = MarkdownTables.blocks(in: "| a \\| b | c |\n| --- | --- |\n| 1 | 2 |\n")
        XCTAssertEqual(escaped.count, 1)
        XCTAssertEqual(escaped[0].columns.count, 2)
        XCTAssertEqual(escaped[0].rows[0].cells.map(\.trimmed), ["a \\| b", "c"])

        let coded = MarkdownTables.blocks(in: "| a `b | c` | d |\n| --- | --- |\n")
        XCTAssertEqual(coded.count, 1)
        XCTAssertEqual(coded[0].rows[0].cells.map(\.trimmed), ["a `b | c`", "d"])
    }

    func testRightAlignPadsTheShortCell() {
        let text = "| A | Q |\n| :- | -: |\n| c | 1 |\n| d | 12 |\n"
        let block = MarkdownTables.blocks(in: text)[0]
        let short = block.rows[2].cells[1]
        XCTAssertEqual(short.align, .right)
        XCTAssertEqual(short.trimmed, "1")
        XCTAssertGreaterThan(short.leadingPad, 0)
        XCTAssertEqual(short.trailingPad, 0)
        XCTAssertNotNil(short.precedingPipe)
        let wide = block.rows[3].cells[1]
        XCTAssertEqual(wide.leadingPad, 0)
        XCTAssertEqual(wide.trailingPad, 0)
    }

    func testAlignedWidthIsTheWidestPaddedRow() {
        let text = "| A | B |\n| - | - |\n| short | x |\n| " + String(repeating: "w", count: 40) + " | y |\n"
        let block = MarkdownTables.blocks(in: text)[0]
        let units = Array(text.utf16)
        let widest = block.rows.map { row in
            String(decoding: units[row.range], as: UTF16.self).count
                + row.cells.reduce(0) { $0 + $1.leadingPad + $1.trailingPad }
        }
        XCTAssertEqual(block.alignedColumns, widest.max())
        XCTAssertEqual(Set(widest).count, 1, "every padded row has the same width")
        XCTAssertTrue(block.alignsWithin(columns: block.alignedColumns))
        XCTAssertFalse(block.alignsWithin(columns: block.alignedColumns - 1))
    }

    func testAlignedWidthCountsWideCharactersAsTwoCells() {
        let block = MarkdownTables.blocks(in: "| 日本 | b |\n| -- | - |\n| ab | c |\n")[0]
        XCTAssertEqual(block.rows[2].cells[0].trailingPad, 2, "\" 日本 \" is 6 cells, \" ab \" is 4")
        XCTAssertEqual(block.alignedColumns, 12, "the header row: 1 + 6 + 1 + 3 + 1")
    }

    func testFormatPadsAndIsIdempotent() {
        let source = "| Name | Qty |\n| :--- | --: |\n| Ada Lovelace | 1 |\n| Linus | 12 |\n"
        let plan = MarkdownTables.plan(in: source, scope: .document, cursor: 0)
        XCTAssertTrue(plan.matched)
        let formatted = apply(plan, to: source)
        XCTAssertEqual(
            formatted,
            """
            | Name         | Qty |
            | :----------- | --: |
            | Ada Lovelace |   1 |
            | Linus        |  12 |
            """ + "\n"
        )
        let again = MarkdownTables.plan(in: formatted, scope: .document, cursor: 0)
        XCTAssertTrue(again.matched)
        XCTAssertTrue(again.rewrites.isEmpty)
        let painted = MarkdownTables.blocks(in: formatted)[0]
        XCTAssertTrue(painted.rows.allSatisfy { row in
            row.cells.allSatisfy { $0.leadingPad == 0 && $0.trailingPad == 0 }
        })
    }

    func testFormatLeavesSurroundingProse() {
        let source = "Hello\n\n| a | bb |\n| - | -- |\n| c | d |\n\nTail\n"
        let plan = MarkdownTables.plan(in: source, scope: .document, cursor: 0)
        let formatted = apply(plan, to: source)
        XCTAssertTrue(formatted.hasPrefix("Hello\n\n"))
        XCTAssertTrue(formatted.hasSuffix("\n\nTail\n"))
        XCTAssertTrue(formatted.contains("| a   | bb  |"))
        XCTAssertTrue(formatted.contains("| c   | d   |"))
    }

    func testCursorStaysOnTheSameCellCharacter() {
        let source = "| Q |\n| -: |\n| 1 |\n| 12 |\n"
        let cursor = utf16Offset(of: "1", in: source)
        let plan = MarkdownTables.plan(in: source, scope: .cursor, cursor: cursor)
        XCTAssertTrue(plan.matched)
        XCTAssertFalse(plan.rewrites.isEmpty)
        let formatted = apply(plan, to: source)
        XCTAssertEqual(character(in: formatted, utf16: plan.cursor), "1")
        XCTAssertNotEqual(plan.cursor, cursor)
    }

    func testScopeFormatsOnlyTheChosenTable() {
        let source = "| a | bb |\n| - | -- |\n\n| c | dd |\n| - | -- |\n"
        let first = MarkdownTables.plan(in: source, scope: .cursor, cursor: 0)
        XCTAssertEqual(first.rewrites.count, 2)
        XCTAssertTrue(first.rewrites.allSatisfy { $0.range.lowerBound < 20 })
        let secondLine = source.utf16.distance(from: source.startIndex, to: source.range(of: "| c |")!.lowerBound)
        let lines = MarkdownTables.plan(in: source, scope: .lines(2...3), cursor: secondLine)
        XCTAssertTrue(lines.matched)
        XCTAssertTrue(lines.rewrites.allSatisfy { slice(source, $0.range).contains("c") || slice(source, $0.range).contains("-") })
        let outside = MarkdownTables.plan(in: source, scope: .cursor, cursor: source.utf16.count)
        XCTAssertFalse(outside.matched)
    }

    func testCodeIndentAndMissingDelimiterAreNotTables() {
        XCTAssertTrue(MarkdownTables.blocks(in: "    | a | b |\n    | - | - |\n").isEmpty)
        XCTAssertTrue(MarkdownTables.blocks(in: "just | prose\n").isEmpty)
        XCTAssertTrue(MarkdownTables.blocks(in: "---\n").isEmpty)
    }

    func testVisibleSliceUsesTheWholeTableForWidths() {
        var lines = (0..<40).map { "Line \($0) with `code` and **bold**.\n" }
        lines.append("| Name | Qty |\n")
        lines.append("| :--- | --: |\n")
        lines.append("| Ada | 1 |\n")
        lines.append("| Linus | 12 |\n")
        let text = lines.joined()
        var tokenizer = MarkdownTokenizer(text: text, scanThroughLine: 2)
        XCTAssertTrue(tokenizer.tableBlocks(overlapping: 0..<8).isEmpty)
        XCTAssertLessThan(tokenizer.scannedLineCount, 10)

        let marker = "| Ada |"
        let start = text.range(of: marker)!
        let utf = text.utf16.distance(from: text.startIndex, to: start.lowerBound)
        let body = tokenizer.tableBlocks(overlapping: utf..<(utf + 1))
        XCTAssertEqual(body.count, 1)
        XCTAssertEqual(body[0].columns.map(\.align), [.left, .right])
        XCTAssertEqual(body[0].rows.map(\.role), [.header, .separator, .body, .body])
        let short = body[0].rows[2].cells[1]
        XCTAssertGreaterThan(short.leadingPad, 0)
        XCTAssertEqual(short.trailingPad, 0)

        let fenced = "para\n```\n| A | B |\n| - | - |\n| c | d |\n```\n"
        var fencedTokenizer = MarkdownTokenizer(text: fenced)
        let hidden = fencedTokenizer.tableBlocks(overlapping: 0..<fenced.utf16.count)
        XCTAssertTrue(hidden.isEmpty)

        let sliced = MarkdownTables.blocks(in: text, overlapping: utf..<(utf + 1))
        XCTAssertEqual(sliced, body)
    }

    func testLengtheningTheWidestCellGrowsTheShortPad() {
        let capped = "| Name | Qty |\n| :--- | --: |\n| Ada | 1 |\n| Linus | 12 |\n"
        let cappedBlock = MarkdownTables.blocks(in: capped)[0]
        let cappedAt = cappedBlock.rows[3].cells[1].text.upperBound
        let cappedAfter = MarkdownTables.blocks(in: insert("3", at: cappedAt, into: capped))[0]
        XCTAssertEqual(
            cappedBlock.rows[2].cells[1].leadingPad,
            cappedAfter.rows[2].cells[1].leadingPad
        )

        let text = "| N | Q |\n| - | -: |\n| c | 1 |\n| d | 12 |\n"
        var tokenizer = MarkdownTokenizer(text: text)
        let before = tokenizer.tableBlocks(overlapping: 0..<text.utf16.count)[0]
        let pad = before.rows[2].cells[1].leadingPad
        XCTAssertGreaterThan(pad, 0)
        let at = before.rows[3].cells[1].text.upperBound
        _ = tokenizer.apply(start: at, removedUTF16: 0, replacement: "3")
        let after = tokenizer.tableBlocks(overlapping: at..<(at + 1))[0]
        XCTAssertGreaterThan(after.rows[2].cells[1].leadingPad, pad)
    }

    func testCompactCellsGetFormatGutters() {
        let block = MarkdownTables.blocks(in: "|a|b|\n|-|-|\n|c|dd|\n")[0]
        let header = block.rows[0].cells[0]
        XCTAssertEqual(header.trimmed, "a")
        XCTAssertGreaterThan(header.leadingPad, 0, "compact `|a|` needs the space `:TableFormat` writes after the pipe")
        XCTAssertGreaterThan(header.trailingPad, 0, "compact `|a|` needs the space before the next pipe")
        let short = block.rows[2].cells[1]
        XCTAssertEqual(short.trimmed, "dd")
        XCTAssertEqual(short.leadingPad, block.rows[0].cells[1].leadingPad)
        XCTAssertGreaterThan(block.rows[0].cells[1].trailingPad, 0)
        let units = Array("|a|b|\n|-|-|\n|c|dd|\n".utf16)
        let padded = block.rows.map { row in
            String(decoding: units[row.range], as: UTF16.self).count
                + row.cells.reduce(0) { $0 + $1.leadingPad + $1.trailingPad }
        }
        XCTAssertEqual(Set(padded).count, 1, "gutter pads still make every row the same width")
    }

    func testFormatPadsByDisplayWidth() {
        let source = "| 日本 | b |\n| -- | - |\n| ab | c |\n"
        let formatted = apply(MarkdownTables.plan(in: source, scope: .document, cursor: 0), to: source)
        XCTAssertEqual(
            formatted,
            """
            | 日本 | b   |
            | ---- | --- |
            | ab   | c   |
            """ + "\n"
        )
        let painted = MarkdownTables.blocks(in: formatted)[0]
        XCTAssertTrue(painted.rows.allSatisfy { row in
            row.cells.allSatisfy { $0.leadingPad == 0 && $0.trailingPad == 0 }
        })
        let again = MarkdownTables.plan(in: formatted, scope: .document, cursor: 0)
        XCTAssertTrue(again.rewrites.isEmpty)
    }

    func testInlineMarkupAndLinksStayInCells() {
        let text = """
        | **Name** | `Qty` | [[note]] | [a](u) |
        | :--- | --: | --- | --- |
        | a \\| b | `x | y` | z | w |
        """
        let blocks = MarkdownTables.blocks(in: text)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].rows[0].cells.map(\.trimmed), ["**Name**", "`Qty`", "[[note]]", "[a](u)"])
        XCTAssertEqual(blocks[0].rows[2].cells.map(\.trimmed), ["a \\| b", "`x | y`", "z", "w"])
        let formatted = apply(MarkdownTables.plan(in: text, scope: .document, cursor: 0), to: text)
        XCTAssertTrue(formatted.contains("**Name**"))
        XCTAssertTrue(formatted.contains("`Qty`"))
        XCTAssertTrue(formatted.contains("[[note]]"))
        XCTAssertTrue(formatted.contains("[a](u)"))
        XCTAssertTrue(formatted.contains("a \\| b"))
        XCTAssertTrue(formatted.contains("`x | y`"))
    }

    func testRowsWithoutOuterPipesAndUnevenColumns() {
        let loose = "Name | Qty\n---: | ---\nAda | 1\nLinus | 12\n"
        let blocks = MarkdownTables.blocks(in: loose)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].rows[0].cells.map(\.trimmed), ["Name", "Qty"])
        XCTAssertNil(blocks[0].rows[0].cells[0].precedingPipe)
        XCTAssertNotNil(blocks[0].rows[0].cells[1].precedingPipe)
        let formatted = apply(MarkdownTables.plan(in: loose, scope: .document, cursor: 0), to: loose)
        XCTAssertTrue(formatted.hasPrefix("|"))
        XCTAssertTrue(formatted.contains("Name"))
        XCTAssertTrue(formatted.contains("Qty"))
        XCTAssertTrue(
            formatted.split(separator: "\n", omittingEmptySubsequences: true)
                .allSatisfy { $0.hasPrefix("|") && $0.hasSuffix("|") }
        )

        let uneven = "| A | B | C |\n| --- | --- |\n| 1 |\n| 1 | 2 | 3 | 4 |\n"
        let wide = MarkdownTables.blocks(in: uneven)[0]
        XCTAssertEqual(wide.columns.count, 4)
        XCTAssertEqual(wide.rows[0].cells.count, 3)
        XCTAssertEqual(wide.rows[2].cells.count, 1)
        XCTAssertEqual(wide.rows[3].cells.count, 4)
        let even = apply(MarkdownTables.plan(in: uneven, scope: .document, cursor: 0), to: uneven)
        let evenLines = even.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.isEmpty }
        XCTAssertTrue(evenLines.allSatisfy { $0.filter { $0 == "|" }.count == 5 })
    }

    func testNeighborhoodCoversOrphanedRowsWhenTheDelimiterBreaks() {
        let text = "| A | B |\n| - | - |\n| c | d |\n"
        var tokenizer = MarkdownTokenizer(text: text)
        XCTAssertEqual(tokenizer.tableBlocks(overlapping: 0..<3).count, 1)
        let sep = tokenizer.lineSpan(1..<2)
        let content = sep.count - 1
        _ = tokenizer.apply(start: sep.lowerBound, removedUTF16: content, replacement: "not a table")
        let edited = sep.lowerBound..<(sep.lowerBound + 1)
        XCTAssertTrue(tokenizer.tableBlocks(overlapping: edited).isEmpty)
        let around = tokenizer.tableNeighborhood(overlapping: edited)
        XCTAssertEqual(around.lowerBound, 0)
        XCTAssertGreaterThan(around.upperBound, sep.lowerBound + 11)

        var split = MarkdownTokenizer(text: text)
        let body = split.lineSpan(2..<3)
        _ = split.apply(start: body.lowerBound, removedUTF16: 0, replacement: "\n")
        XCTAssertEqual(split.tableBlocks(overlapping: 0..<8).count, 1)
        XCTAssertEqual(split.tableBlocks(overlapping: 0..<8)[0].rows.count, 2)
        let both = split.tableNeighborhood(overlapping: body.lowerBound..<(body.lowerBound + 1))
        XCTAssertEqual(both.lowerBound, 0)
        XCTAssertGreaterThan(both.upperBound, body.lowerBound)
    }
}

private func insert(_ text: String, at utf16: Int, into source: String) -> String {
    var units = Array(source.utf16)
    units.insert(contentsOf: Array(text.utf16), at: utf16)
    return String(decoding: units, as: UTF16.self)
}

private func apply(_ plan: TablePlan, to text: String) -> String {
    var units = Array(text.utf16)
    for rewrite in plan.rewrites.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
        units.replaceSubrange(rewrite.range, with: Array(rewrite.replacement.utf16))
    }
    return String(decoding: units, as: UTF16.self)
}

private func slice(_ text: String, _ range: Range<Int>) -> String {
    let units = Array(text.utf16)
    return String(decoding: units[range], as: UTF16.self)
}

private func utf16Offset(of character: Character, in text: String) -> Int {
    let index = text.firstIndex(of: character)!
    return text.utf16.distance(from: text.startIndex, to: index)
}

private func character(in text: String, utf16: Int) -> Character {
    let units = Array(text.utf16)
    let prefix = String(decoding: units[..<utf16], as: UTF16.self)
    return text[text.index(text.startIndex, offsetBy: prefix.count)]
}
