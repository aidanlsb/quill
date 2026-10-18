import XCTest
@testable import QuillSearch

final class PickerEngineTests: XCTestCase {
    func sample() -> PickerEngine {
        PickerEngine(source: [
            PickerItem(title: "notes.md", payload: "/notes.md", preview: "# Notes"),
            PickerItem(title: "ideas.md", payload: "/ideas.md", preview: "# Ideas"),
            PickerItem(title: "todo.md", payload: "/todo.md", preview: "- [ ] write"),
        ])
    }

    func testOpensInInsert() {
        XCTAssertEqual(sample().mode, .insert)
    }

    func testInsertFiltersAndCtrlNP() {
        let p = sample()
        XCTAssertEqual(p.handle(.ctrl("n")), .none)
        XCTAssertEqual(p.selectedIndex, 1)
        XCTAssertEqual(p.handle(.ctrl("p")), .none)
        XCTAssertEqual(p.selectedIndex, 0)
        XCTAssertEqual(p.mode, .insert)

        XCTAssertEqual(p.handle(.character("n")), .none)
        XCTAssertEqual(p.items.map(\.title), ["notes.md"])
        _ = p.handle(.character("x"))
        XCTAssertTrue(p.items.isEmpty)
        _ = p.handle(.backspace)
        XCTAssertEqual(p.items.first?.title, "notes.md")
        XCTAssertEqual(p.mode, .insert)
    }

    func testEscapeEntersNormalThenJKGG() {
        let p = sample()
        XCTAssertEqual(p.handle(.escape), .none)
        XCTAssertEqual(p.mode, .normal)
        XCTAssertEqual(p.handle(.character("j")), .none)
        XCTAssertEqual(p.selectedIndex, 1)
        XCTAssertEqual(p.handle(.character("k")), .none)
        XCTAssertEqual(p.selectedIndex, 0)
        XCTAssertEqual(p.handle(.character("G")), .none)
        XCTAssertEqual(p.selectedIndex, 2)
        XCTAssertEqual(p.handle(.character("g")), .none)
        XCTAssertEqual(p.handle(.character("g")), .none)
        XCTAssertEqual(p.selectedIndex, 0)
    }

    func testNormalEnterConfirmsIAReturnsInsertQCloses() {
        let p = sample()
        _ = p.handle(.escape)
        XCTAssertEqual(p.handle(.enter), .confirm)
        XCTAssertEqual(p.handle(.character("i")), .none)
        XCTAssertEqual(p.mode, .insert)
        _ = p.handle(.escape)
        XCTAssertEqual(p.handle(.character("a")), .none)
        XCTAssertEqual(p.mode, .insert)
        XCTAssertEqual(p.queryCursor, p.query.count)
        _ = p.handle(.escape)
        XCTAssertEqual(p.handle(.character("q")), .close)
        XCTAssertEqual(p.handle(.escape), .close)
    }

    func testInsertEnterConfirmsWithoutLeavingInsert() {
        let p = sample()
        XCTAssertEqual(p.mode, .insert)
        XCTAssertEqual(p.handle(.enter), .confirm)
        XCTAssertEqual(p.mode, .insert)
    }

    func testNormalDoesNotEditQuery() {
        let p = sample()
        _ = p.handle(.character("n"))
        XCTAssertEqual(p.query, "n")
        _ = p.handle(.escape)
        XCTAssertEqual(p.handle(.character("j")), .none)
        XCTAssertEqual(p.query, "n")
        XCTAssertEqual(p.mode, .normal)
        XCTAssertEqual(p.selectedIndex, 0)
    }

    func testQueryStaysPlainText() {
        let p = sample()
        XCTAssertEqual(p.query, "")
        XCTAssertEqual(p.mode, .insert)
        _ = p.handle(.character("n"))
        XCTAssertEqual(p.query, "n")
        XCTAssertEqual(p.queryCursor, 1)
        XCTAssertFalse(p.query.contains("▏"))
        _ = p.handle(.escape)
        XCTAssertEqual(p.mode, .normal)
        XCTAssertEqual(p.query, "n")
        _ = p.handle(.character("i"))
        XCTAssertEqual(p.mode, .insert)
        XCTAssertEqual(p.query, "n")
    }

    func testReplacingSourceRefilters() {
        let p = PickerEngine()
        p.source = [PickerItem(title: "notes.md", payload: "notes.md")]
        XCTAssertEqual(p.items.map(\.title), ["notes.md"])
        _ = p.handle(.character("z"))
        XCTAssertTrue(p.items.isEmpty)
    }

    func testHighlightRanges() {
        XCTAssertEqual(
            PickerHighlight.ranges(query: "no", candidate: "notes.md", style: .fuzzy),
            [0..<2]
        )
        XCTAssertEqual(
            PickerHighlight.ranges(query: "nm", candidate: "notes.md", style: .fuzzy),
            [0..<1, 6..<7]
        )
        XCTAssertTrue(PickerHighlight.ranges(query: "zz", candidate: "notes.md", style: .fuzzy).isEmpty)
        XCTAssertTrue(PickerHighlight.ranges(query: "", candidate: "notes.md", style: .fuzzy).isEmpty)
        XCTAssertEqual(
            PickerHighlight.ranges(query: "Alpha", candidate: "alpha notes", style: .literal),
            [0..<5]
        )
        XCTAssertEqual(
            PickerHighlight.ranges(query: "a", candidate: "alpha", style: .literal),
            [0..<1, 4..<5]
        )
        let pairs = [("no", "notes.md"), ("nm", "notes.md"), ("md", "notes.md"), ("zz", "notes.md")]
        for (query, candidate) in pairs {
            let scored = Fuzzy.score(query: query, candidate: candidate) != nil
            let ranges = PickerHighlight.ranges(query: query, candidate: candidate, style: .fuzzy)
            let chars = Array(candidate.lowercased())
            let matched = ranges.flatMap { Array(chars[$0]) }.map(String.init).joined()
            if scored {
                XCTAssertEqual(matched, query.lowercased(), query)
            } else {
                XCTAssertTrue(ranges.isEmpty, query)
            }
        }
    }

    func testEmptyConfirmIsNone() {
        let p = PickerEngine(source: [])
        XCTAssertEqual(p.handle(.enter), .none)
        _ = p.handle(.escape)
        XCTAssertEqual(p.handle(.enter), .none)
    }

    func testDuplicateTitlesStayDistinct() {
        let p = PickerEngine(source: [
            PickerItem(title: "note.md", payload: "/a/note.md"),
            PickerItem(title: "note.md", payload: "/b/note.md"),
        ])
        _ = p.handle(.character("n"))
        XCTAssertEqual(p.items.map(\.payload), ["/a/note.md", "/b/note.md"])
    }

    func testQueryChangeDoesNotBlockInsideTheEngine() {
        let p = PickerEngine()
        var seen: [String] = []
        p.onQueryChange = { seen.append($0) }
        _ = p.handle(.character("a"))
        XCTAssertEqual(seen, ["a"])
        XCTAssertTrue(p.items.isEmpty)
        p.replaceItems([PickerItem(title: "a.md", payload: "a.md", preview: "")])
        XCTAssertEqual(p.items.count, 1)
        p.updatePreview(payload: "a.md", text: "body")
        XCTAssertEqual(p.selected?.preview, "body")
    }

    func testLiveGrepQuery() {
        let p = PickerEngine(liveSearch: { q in
            if q.isEmpty { return [] }
            return [PickerItem(title: "a.md:2", subtitle: q, payload: "a.md:2", preview: q)]
        })
        _ = p.handle(.character("x"))
        XCTAssertEqual(p.items.count, 1)
        XCTAssertEqual(p.items[0].subtitle, "x")
    }
}
