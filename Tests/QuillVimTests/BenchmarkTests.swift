import XCTest
@testable import QuillVim

final class BenchmarkTests: XCTestCase {
    func testInsertOnALongBufferStaysResponsive() {
        let text = Array(repeating: "word", count: 2000).joined(separator: "\n")
        let engine = Engine(text: text, cursor: text.utf16.count)
        let start = ContinuousClock().now
        _ = engine.type("Ax<Esc>")
        let elapsed = start.duration(to: .now)
        XCTAssertLessThan(elapsed, .seconds(2))
        XCTAssertTrue(engine.text.hasSuffix("x"))
    }
}
