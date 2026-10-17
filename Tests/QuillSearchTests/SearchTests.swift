import XCTest
import Foundation
@testable import QuillSearch

private final class DrainResult: @unchecked Sendable {
    var stdout = Data()
    var stderr = Data()
}

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

    func testDashQueryIsPassedWithE() {
        let args = ContentSearch.arguments(query: "-foo", root: "/notes", limit: 50, includeHidden: false)
        XCTAssertTrue(args.contains("-e"))
        XCTAssertEqual(args[args.firstIndex(of: "-e")! + 1], "-foo")
        XCTAssertTrue(args.contains("--"))
        XCTAssertFalse(args.contains("--hidden"))
        let hidden = ContentSearch.arguments(query: "a", root: "/notes", limit: 1, includeHidden: true)
        XCTAssertTrue(hidden.contains("--hidden"))
    }

    func testNormalizeAbsoluteVimgrepPaths() {
        let root = "/tmp/rgprobe"
        let text = "\(root)/sub/a.md:1:7:hello needle\n/other:name.md:4:1:needle\n"
        let hits = ContentSearch.parseVimgrep(text, root: root, limit: 10)
        XCTAssertEqual(hits.map(\.path), ["sub/a.md", "/other:name.md"])
        XCTAssertEqual(hits[0].line, 1)
        XCTAssertEqual(hits[0].snippet, "hello needle")
        XCTAssertEqual(hits[1].line, 4)
    }

    func testIgnoreNegationAndDoubleStar() {
        let rules = IgnoreRules(patterns: ["**/*.tmp", "*.md", "!keep.md", "secret/"])
        XCTAssertTrue(rules.ignores(relativePath: "nested/dir/file.tmp", isDirectory: false))
        XCTAssertTrue(rules.ignores(relativePath: "notes.md", isDirectory: false))
        XCTAssertFalse(rules.ignores(relativePath: "keep.md", isDirectory: false))
        XCTAssertTrue(rules.ignores(relativePath: "secret/note.txt", isDirectory: false))
    }

    func testDrainDoesNotDeadlockOnLargeOutput() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "dd if=/dev/zero bs=1024 count=200 2>/dev/null; echo stderr-ok >&2"]
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()
        let done = expectation(description: "drained")
        let box = DrainResult()
        Thread {
            let pair = ContentSearch.drain(
                stdout: out.fileHandleForReading,
                stderr: err.fileHandleForReading,
                process: proc
            )
            box.stdout = pair.0
            box.stderr = pair.1
            done.fulfill()
        }.start()
        wait(for: [done], timeout: 5)
        XCTAssertGreaterThan(box.stdout.count, 64 * 1024)
        XCTAssertTrue(String(data: box.stderr, encoding: .utf8)?.contains("stderr-ok") == true)
        XCTAssertEqual(proc.terminationStatus, 0)
    }
}
