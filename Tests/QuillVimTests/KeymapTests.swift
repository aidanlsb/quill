import XCTest
@testable import QuillVim

final class KeymapTests: XCTestCase {
    func testExactPrefixAndMiss() {
        var map = Keymap()
        map.bind("gd", command: "def")
        map.bind("gr", command: "refs")
        XCTAssertEqual(map.lookup("g"), .prefix)
        XCTAssertEqual(map.lookup("gd"), .command("def"))
        XCTAssertEqual(map.lookup("gr"), .command("refs"))
        XCTAssertEqual(map.lookup("gx"), .none)
        XCTAssertEqual(map.lookup("gdx"), .none)
        XCTAssertEqual(map.lookup(""), .none)
    }

    func testRebindingReplacesTheCommandAndKeepsThePrefix() {
        var map = Keymap()
        map.bind("gd", command: "def")
        map.bind("gd", command: "other")
        XCTAssertEqual(map.lookup("gd"), .command("other"))
        XCTAssertEqual(map.lookup("g"), .prefix)
        map.bind("g", command: "just-g")
        XCTAssertEqual(map.lookup("g"), .command("just-g"))
        XCTAssertEqual(map.lookup("gd"), .command("other"))
    }

    func testAngleBracketKeysAreOneAtom() {
        var map = Keymap()
        map.bind("<CR>", command: "open")
        let first = map.lookup("<CR>")
        map.bind("gd", command: "def")
        let second = map.lookup("<CR>")
        XCTAssertEqual(first, .command("open"), "first \(String(describing: first))")
        XCTAssertEqual(second, .command("open"), "second \(String(describing: second))")
        XCTAssertEqual(map.lookup("<"), .none)
        XCTAssertEqual(map.lookup("<C"), .none)
        XCTAssertEqual(map.lookup("g"), .prefix)
    }

    func testTwoHundredKeys() {
        var map = Keymap()
        for index in 0..<200 {
            map.bind(String(format: "k%03d", index), command: "c\(index)")
        }
        XCTAssertEqual(map.lookup("k042"), .command("c42"))
        XCTAssertEqual(map.lookup("k000"), .command("c0"))
        XCTAssertEqual(map.lookup("k199"), .command("c199"))
        XCTAssertEqual(map.lookup("k04"), .prefix)
        XCTAssertEqual(map.lookup("k"), .prefix)
        XCTAssertEqual(map.lookup("nope"), .none)
        XCTAssertEqual(map.lookup("k200"), .none)
    }
}
