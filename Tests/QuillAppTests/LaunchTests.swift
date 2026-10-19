import XCTest
@testable import Quill

/// What a launched process proves is `AppSmoke`. This checks the same wiring in process.
final class LaunchTests: QuillAppTestCase {
    @MainActor
    func testTypingThroughKeyDownEditsTheStorage() {
        let harness = EditorHarness(text: "")
        defer { harness.close() }
        harness.type("ihello<Esc>")
        XCTAssertEqual(harness.engine.text, "hello")
        XCTAssertEqual(harness.view.string, "hello")
    }

    @MainActor
    func testModelHostUsesTheModelsEngine() {
        let model = AppModel()
        let harness = EditorHarness(model: model)
        defer { harness.close() }
        XCTAssertTrue(harness.view.engine === model.engine)
        XCTAssertTrue(harness.scroll.documentView === harness.view)
        harness.resize(to: NSSize(width: 900, height: 500))
        XCTAssertEqual(harness.engine.text, model.engine.text)
    }
}
