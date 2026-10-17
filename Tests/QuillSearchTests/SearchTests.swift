import XCTest
import Foundation
@testable import QuillSearch

final class FuzzyTests: XCTestCase {
    func testSubsequence() {
        XCTAssertNotNil(Fuzzy.score(query: "ql", candidate: "Quill.md"))
        XCTAssertNil(Fuzzy.score(query: "zx", candidate: "Quill.md"))
    }

    func testPrefersPrefix() {
        let ranked = Fuzzy.rank(query: "no", candidates: ["another-note.md", "notes.md", "README.md"])
        XCTAssertEqual(ranked.first?.value, "notes.md")
    }

    func testEmptyQueryMatchesAll() {
        let ranked = Fuzzy.rank(query: "", candidates: ["a.md", "b.md"])
        XCTAssertEqual(ranked.count, 2)
    }

    func testBoundaryBonus() {
        let a = Fuzzy.score(query: "md", candidate: "foo.md")!
        let b = Fuzzy.score(query: "md", candidate: "mado.md")!
        XCTAssertGreaterThan(a, b)
    }
}

final class IgnoreAndGrepTests: XCTestCase {
    func testIgnoreGitAndDot() {
        let rules = IgnoreRules(patterns: ["build/", "*.tmp"])
        XCTAssertTrue(rules.ignores(relativePath: ".git/config", isDirectory: false))
        XCTAssertTrue(rules.ignores(relativePath: ".hidden", isDirectory: true))
        XCTAssertTrue(rules.ignores(relativePath: "build/out", isDirectory: false))
        XCTAssertTrue(rules.ignores(relativePath: "foo.tmp", isDirectory: false))
        XCTAssertFalse(rules.ignores(relativePath: "notes.md", isDirectory: false))
    }

    func testNativeGrep() {
        let hits = ContentSearch.grep(query: "wikilink", files: [
            ("a.md", "# Title\nSee [[wikilink]] here\n"),
            ("b.md", "nothing\n"),
        ])
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].path, "a.md")
        XCTAssertEqual(hits[0].line, 2)
        XCTAssertTrue(hits[0].snippet.contains("wikilink"))
    }

    func testWalkRespectsIgnore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quill-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "hello target".write(to: root.appendingPathComponent("keep.md"), atomically: true, encoding: .utf8)
        let git = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "secret target".write(to: git.appendingPathComponent("config.md"), atomically: true, encoding: .utf8)
        try "skip".write(to: root.appendingPathComponent("ignore.tmp"), atomically: true, encoding: .utf8)
        try "*.tmp\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)

        let ignore = IgnoreRules.load(from: root)
        let files = FileWalk.files(in: root, ignore: ignore)
        let names = Set(files.map(\.lastPathComponent))
        XCTAssertTrue(names.contains("keep.md"))
        XCTAssertFalse(names.contains("config.md"))
        XCTAssertFalse(names.contains("ignore.tmp"))

        let hits = ContentSearch.search(root: root, query: "target", ignore: ignore)
        XCTAssertTrue(hits.contains { $0.path.hasSuffix("keep.md") })
        XCTAssertFalse(hits.contains { $0.path.contains(".git") })
    }
}
