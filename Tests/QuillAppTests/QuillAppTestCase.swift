import AppKit
import XCTest

/// AppKit tests share one application object. `NSApplication.shared`, never bare `NSApp`.
class QuillAppTestCase: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            _ = NSApplication.shared
        }
    }
}
