import XCTest
import QuillVim
@testable import Quill

/// The command table is the keymap, the ex lookup, and the palette labels.
@MainActor
final class CommandDispatchTests: QuillAppTestCase {
    func testPaletteKeepsCommandPaletteAndToggleImages() {
        let model = AppModel()
        XCTAssertTrue(model.runCommand("search.commands"))
        XCTAssertEqual(model.pickerKind, .commands)
        let focus = subtitle("view.focus", in: model)
        XCTAssertEqual(focus, "\u{2303}\u{2318}F")
        XCTAssertTrue(model.commands.entries.contains { $0.id == "view.toggleImages" })
        model.dismissCommandPalette(restore: false)
        let images = model.showImages
        XCTAssertTrue(model.runCommand("view.toggleImages"))
        XCTAssertNotEqual(model.showImages, images)
    }

    func testPaletteShowsTheBindingsThatDispatch() {
        let model = AppModel()
        model.presentCommandPalette()
        XCTAssertEqual(subtitle("file.parent", in: model), "-")
        XCTAssertEqual(subtitle("navigate.references", in: model), "gr")
        XCTAssertEqual(subtitle("navigate.codeAction", in: model), "<leader>ca")
        XCTAssertTrue(subtitle("navigate.definition", in: model).contains("gd"))
        XCTAssertTrue(subtitle("search.files", in: model).contains("<leader>sf"))
        XCTAssertTrue(subtitle("file.save", in: model).contains(":w"))
        model.dismissCommandPalette(restore: false)

        var config = QuillConfig.default
        config.leaderMaps = ["xx": "search.grep"]
        config.apply(to: model)
        model.presentCommandPalette()
        XCTAssertTrue(subtitle("search.grep", in: model).contains("<leader>xx"))
        model.dismissCommandPalette(restore: false)

        let result = model.engine.type(" xx")
        model.afterEdit(result)
        XCTAssertEqual(result.actions, [.command("search.grep")])
        XCTAssertEqual(model.pickerKind, .grep)
    }

    func testUnknownLeaderMapIsReported() {
        let model = AppModel()
        var config = QuillConfig.default
        config.leaderMaps = ["xy": "foo"]
        config.loadNotice = nil
        config.apply(to: model)
        XCTAssertTrue(model.message.contains("leaderMaps.xy: no command foo"))
    }

    func testLeaderKeysOpenThePickerAndToggleTheTheme() async throws {
        let fixture = try TempDirectory()
        try fixture.write("notes.md", "hello\n")
        let model = AppModel()
        let url = fixture.url.appendingPathComponent("notes.md")
        model.open(url: url)
        await waitUntil("open") { model.engine.text == "hello\n" }
        let theme = model.themeChoice
        model.afterEdit(model.engine.type(" sf"))
        await waitUntil("find files") { model.pickerKind == .files }
        model.picker = nil
        model.pickerKind = nil
        model.afterEdit(model.engine.type(" tt"))
        XCTAssertNotEqual(model.themeChoice, theme)
        withExtendedLifetime(fixture) {}
    }

    func testGoToDefinitionOpensAWikilink() async throws {
        let fixture = try TempDirectory()
        try fixture.write("note.md", "see [[target]]\n")
        try fixture.write("target.md", "from the link\n")
        let model = AppModel()
        model.open(url: fixture.url.appendingPathComponent("note.md"))
        await waitUntil("open note") { model.engine.text.contains("[[target]]") }
        model.engine.moveCursor(to: 6)
        model.afterEdit(model.engine.type("gd"))
        await waitUntil("wikilink") { model.engine.text.contains("from the link") }
        withExtendedLifetime(fixture) {}
    }

    func testDirectoryEnterOpensAndFileEnterMovesDown() async throws {
        let fixture = try TempDirectory()
        try fixture.write("notes.md", "hello notes\n")
        let model = AppModel()
        model.open(url: fixture.url)
        await waitUntil("directory") { model.isDirectory && model.engine.text.contains("notes.md") }
        XCTAssertEqual(model.engine.keymap.lookup("<CR>"), .command("file.openEntry"))
        var steps = 0
        while !model.engine.lineTextUnderCursor().hasPrefix("notes.md"), steps < 10 {
            model.afterEdit(model.engine.type("j"))
            steps += 1
        }
        model.afterEdit(model.engine.type("<CR>"))
        await waitUntil("opened notes") { model.engine.text.contains("hello notes") }
        XCTAssertEqual(model.engine.keymap.lookup("<CR>"), .none)
        model.engine.load(text: "a\nb\n")
        model.afterEdit(model.engine.type("<CR>"))
        XCTAssertEqual(model.engine.buffer.lineIndex(containing: model.engine.cursor), 1)
        withExtendedLifetime(fixture) {}
    }

    func testReloadAndQuit() async throws {
        let fixture = try TempDirectory()
        try fixture.write("note.md", "hello\n")
        let url = fixture.url.appendingPathComponent("note.md")
        let model = AppModel()
        model.open(url: url)
        await waitUntil("open") { model.engine.text == "hello\n" }

        model.engine.applyHostEdit(replacing: 5..<5, with: "!")
        model.afterEdit(model.engine.type(":e<CR>"))
        XCTAssertEqual(model.message, "No write since last change")
        XCTAssertEqual(model.engine.text, "hello!\n")

        model.afterEdit(model.engine.type(":e!<CR>"))
        await waitUntil("reload bang") { model.engine.text == "hello\n" }

        try Data("changed\n".utf8).write(to: url)
        model.afterEdit(model.engine.type(":e<CR>"))
        await waitUntil("reload") { model.engine.text == "changed\n" }

        model.engine.applyHostEdit(replacing: 0..<0, with: "x")
        model.afterEdit(model.engine.type(":q<CR>"))
        XCTAssertEqual(model.message, "No write since last change")
        XCTAssertEqual(model.closeRequests, 0)
        model.afterEdit(model.engine.type(":q!<CR>"))
        XCTAssertEqual(model.closeRequests, 1)
        XCTAssertFalse(model.engine.isModified)
        withExtendedLifetime(fixture) {}
    }

    func testThemeExAndLegacyLeaderNames() {
        let model = AppModel()
        model.afterEdit(model.engine.type(":theme dark<CR>"))
        XCTAssertEqual(model.themeChoice, .dark)
        model.afterEdit(model.engine.type(":theme blue<CR>"))
        XCTAssertEqual(model.message, "theme must be light, dark, or system")
        XCTAssertEqual(model.themeChoice, .dark)
        model.afterEdit(model.engine.type(":theme<CR>"))
        XCTAssertNotEqual(model.themeChoice, .dark)
        XCTAssertEqual(QuillConfig.commandID(named: "findFiles"), "search.files")
        XCTAssertEqual(QuillConfig.commandID(named: "liveGrep"), "search.grep")
        XCTAssertEqual(QuillConfig.commandID(named: "toggleTheme"), "view.toggleTheme")
    }

    private func subtitle(_ id: String, in model: AppModel) -> String {
        model.picker?.items.first { $0.payload == id }?.subtitle ?? ""
    }

    private func waitUntil(
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: @MainActor @escaping () -> Bool
    ) async {
        let clock = ContinuousClock()
        let start = clock.now
        while !predicate() {
            if clock.now - start > .seconds(3) {
                XCTFail(description, file: file, line: line)
                return
            }
            await Task.yield()
        }
    }
}
