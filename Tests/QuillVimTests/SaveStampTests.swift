import XCTest
@testable import QuillVim

final class SaveStampTests: XCTestCase {
    func testEditAfterTheCapturedStampStaysModified() {
        let engine = Engine(text: "ab")
        engine.type("x")
        let stamp = engine.changeStamp
        engine.type("x")
        engine.markSaved(stamp: stamp)
        XCTAssertNotEqual(engine.changeStamp, stamp)
        XCTAssertTrue(engine.isModified)
    }

    func testUndoBackToTheSavedStampClearsModified() {
        let engine = Engine(text: "ab")
        engine.type("x")
        let stamp = engine.changeStamp
        engine.type("x")
        engine.markSaved(stamp: stamp)
        XCTAssertTrue(engine.isModified)

        engine.type("u")
        XCTAssertEqual(engine.changeStamp, stamp)
        XCTAssertFalse(engine.isModified)

        engine.type("<C-r>")
        XCTAssertTrue(engine.isModified)

        engine.type("u")
        XCTAssertFalse(engine.isModified)
        engine.type("u")
        XCTAssertTrue(engine.isModified, "undoing past the saved snapshot is a new unsaved state")
    }

    func testMarkSavedClearsTheCurrentStamp() {
        let engine = Engine(text: "ab")
        engine.type("x")
        let stamp = engine.changeStamp
        engine.markSaved()
        XCTAssertFalse(engine.isModified)
        engine.type("x")
        XCTAssertNotEqual(engine.changeStamp, stamp)
        XCTAssertTrue(engine.isModified)
    }
}
