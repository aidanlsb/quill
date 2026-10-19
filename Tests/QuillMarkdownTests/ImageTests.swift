import XCTest
@testable import QuillMarkdown

final class ImageTests: XCTestCase {
    func testFindInlineImages() {
        let text = """
        ---
        title: ![front](no.png)
        ---
        before
        ![Alt](./pic.png)
        ![a](https://example.com/a.png "title")
        ![](<my file.png>)
        See ![x](y.png) and ![z](w.png).
        not ![ref][id]
        a [link](no.png)
        `![no](skip.png)` and ![yes](ok.png)
        ```
        ![nope](no.png)
        ```
        tail ![esc](keep.png)
        \\![no](skip.png)
        """
        let images = MarkdownImages.find(in: text)
        let destinations = images.map(\.destination)
        XCTAssertEqual(destinations, [
            "./pic.png",
            "https://example.com/a.png",
            "my file.png",
            "y.png",
            "w.png",
            "ok.png",
            "keep.png",
        ])
        XCTAssertEqual(images[0].alt, "Alt")
        XCTAssertEqual(images[0].line, 4)
        XCTAssertEqual(images[2].alt, "")
        XCTAssertFalse(images.contains { $0.destination == "no.png" })
        XCTAssertFalse(images.contains { $0.destination == "skip.png" })
        let source = utf16(text, images[0].range)
        XCTAssertEqual(source, "![Alt](./pic.png)")
    }

    func testFindSkipsAFenceAndKeepsTheFollowingImage() {
        let text = "```swift\n![a](no.png)\n```\n![b](yes.png)\n"
        let images = MarkdownImages.find(in: text)
        XCTAssertEqual(images.map(\.destination), ["yes.png"])
        XCTAssertEqual(images[0].line, 3)
    }

    func testResolvePaths() {
        let file = "/notes/draft/post.md"
        let home = "/Users/ada"
        XCTAssertEqual(
            ImagePaths.resolve("./pic.png", filePath: file, home: home),
            .local(path: "/notes/draft/pic.png")
        )
        XCTAssertEqual(
            ImagePaths.resolve("../img/a.png", filePath: file, home: home),
            .local(path: "/notes/img/a.png")
        )
        XCTAssertEqual(
            ImagePaths.resolve("/var/pic.png", filePath: nil, home: home),
            .local(path: "/var/pic.png")
        )
        XCTAssertEqual(
            ImagePaths.resolve("~/photos/a.png", filePath: nil, home: home),
            .local(path: "/Users/ada/photos/a.png")
        )
        XCTAssertEqual(
            ImagePaths.resolve("~/photos/a.png", filePath: nil, home: "/Users/ada/"),
            .local(path: "/Users/ada/photos/a.png")
        )
        XCTAssertEqual(
            ImagePaths.resolve("https://example.com/a.png", filePath: nil, home: home),
            .remote(url: "https://example.com/a.png")
        )
        XCTAssertEqual(
            ImagePaths.resolve("HTTP://example.com/a.png", filePath: nil, home: home),
            .remote(url: "HTTP://example.com/a.png")
        )
        XCTAssertEqual(
            ImagePaths.resolve("file:///Users/ada/a%20b.png", filePath: nil, home: home),
            .local(path: "/Users/ada/a b.png")
        )
        XCTAssertEqual(
            ImagePaths.resolve("pics/a%20b.png", filePath: file, home: home),
            .local(path: "/notes/draft/pics/a b.png")
        )
        XCTAssertNil(ImagePaths.resolve("pics/a.png", filePath: nil, home: home))
        XCTAssertNil(ImagePaths.resolve("~ada/a.png", filePath: file, home: home))
        XCTAssertNil(ImagePaths.resolve("https://", filePath: nil, home: home))
        XCTAssertEqual(
            ImagePaths.resolve("/notes/../img/./a.png", filePath: nil, home: home),
            .local(path: "/img/a.png")
        )
    }

    func testCacheHitsMtimeAndEvicts() {
        var cache = ImageCache<String>(limit: 2)
        let path = "file:/notes/a.png"
        cache.store("one", for: .init(identity: path, modified: 10))
        XCTAssertEqual(cache.value(for: .init(identity: path, modified: 10)), "one")
        XCTAssertNil(cache.value(for: .init(identity: path, modified: 11)))
        XCTAssertNil(cache.stored(identity: path)?.value, "a stale mtime drops the entry")

        cache.store("a", for: .init(identity: "a", modified: 1))
        cache.store("b", for: .init(identity: "b", modified: 1))
        cache.store("c", for: .init(identity: "c", modified: 1))
        XCTAssertNil(cache.stored(identity: "a")?.value)
        XCTAssertEqual(cache.stored(identity: "b")?.value, "b")
        cache.store("d", for: .init(identity: "d", modified: 1))
        XCTAssertNil(cache.stored(identity: "c")?.value, "the least recently used entry leaves")
        XCTAssertEqual(cache.stored(identity: "b")?.value, "b")
        XCTAssertEqual(cache.count, 2)

        cache.invalidate(identity: "b")
        XCTAssertNil(cache.stored(identity: "b")?.value)
        let remote = ImageCache<String>.Key(identity: "url:https://example.com/a.png", modified: nil)
        cache.store("remote", for: remote)
        XCTAssertEqual(cache.value(for: remote), "remote")
    }

    func testFitKeepsAspectAndCapsHeight() {
        let wide = ImageFit.displaySize(pixelWidth: 400, pixelHeight: 100, columnWidth: 200)
        XCTAssertEqual(wide.width, 200, accuracy: 0.01)
        XCTAssertEqual(wide.height, 50, accuracy: 0.01)
        let tall = ImageFit.displaySize(pixelWidth: 100, pixelHeight: 400, columnWidth: 200)
        XCTAssertEqual(tall.height, ImageFit.maxHeight, accuracy: 0.01)
        XCTAssertEqual(tall.width, 90, accuracy: 0.01)
        XCTAssertLessThanOrEqual(tall.width, 200)
        let missing = ImageFit.displaySize(pixelWidth: 0, pixelHeight: 0, columnWidth: 200)
        XCTAssertEqual(missing.height, ImageFit.placeholderHeight, accuracy: 0.01)
        XCTAssertEqual(ImageFit.screenRows(height: 72, rowHeight: 24), 3)
        XCTAssertEqual(ImageFit.spacing(heights: [72]), 84, accuracy: 0.01)
        XCTAssertEqual(ImageFit.spacing(heights: [72, 40]), 130, accuracy: 0.01)
    }

    func testManyImagesStayASinglePass() {
        let body = (0..<100).map { "note \($0)\n![fig](figures/\($0).png)\n" }.joined()
        let images = MarkdownImages.find(in: body)
        XCTAssertEqual(images.count, 100)
        XCTAssertEqual(images[99].destination, "figures/99.png")
        XCTAssertEqual(images[99].line, 199)
    }

    private func utf16(_ text: String, _ range: Range<Int>) -> String {
        let view = text.utf16
        let start = view.index(view.startIndex, offsetBy: range.lowerBound)
        let end = view.index(start, offsetBy: range.count)
        return String(decoding: view[start..<end], as: UTF16.self)
    }
}
