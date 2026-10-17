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

    func testInsertPromptShowsCaret() {
        let p = sample()
        XCTAssertEqual(p.promptDisplay, "▏")
        _ = p.handle(.character("n"))
        XCTAssertEqual(p.promptDisplay, "n▏")
        _ = p.handle(.escape)
        XCTAssertEqual(p.promptDisplay, "n")
        _ = p.handle(.character("i"))
        XCTAssertEqual(p.promptDisplay, "n▏")
    }

    func testEmptyConfirmIsNone() {
        let p = PickerEngine(source: [])
        XCTAssertEqual(p.handle(.enter), .none)
        _ = p.handle(.escape)
        XCTAssertEqual(p.handle(.enter), .none)
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
