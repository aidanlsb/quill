import XCTest
import QuillVim
@testable import QuillSearch

final class CommandRegistryTests: XCTestCase {
    private func sample() -> [CommandEntry] {
        [
            CommandEntry(
                id: "file.save",
                name: "Save",
                category: "File",
                bindings: [
                    .init(.chord(key: "s", command: true, shift: false, option: false, control: false)),
                    .init(.ex("w")),
                ],
                showsInMenu: true
            ),
            CommandEntry(
                id: "search.files",
                name: "Find Files",
                category: "Search",
                bindings: [
                    .init(.chord(key: "p", command: true, shift: false, option: false, control: false)),
                    .init(.leader("sf")),
                ],
                showsInMenu: true
            ),
            CommandEntry(
                id: "view.focus",
                name: "Focus Mode",
                category: "View",
                bindings: [
                    .init(.chord(key: "f", command: true, shift: false, option: false, control: true)),
                ],
                showsInMenu: true
            ),
            CommandEntry(
                id: "view.theme",
                name: "Toggle Light/Dark",
                category: "View",
                bindings: [
                    .init(.chord(key: "l", command: true, shift: true, option: false, control: false)),
                    .init(.leader("tt")),
                    .init(.ex("theme")),
                ],
                showsInMenu: true
            ),
        ]
    }

    func testEmptyQueryRanksRecentFirstThenRegistrationOrder() {
        let entries = sample()
        let ranked = CommandRanking.ranked(entries: entries, query: "", recent: ["view.focus", "file.save"])
        XCTAssertEqual(ranked.map(\.id), ["view.focus", "file.save", "search.files", "view.theme"])
    }

    func testUnknownRecentIDIsIgnored() {
        let ranked = CommandRanking.ranked(entries: sample(), query: "", recent: ["missing", "view.theme"])
        XCTAssertEqual(ranked.map(\.id), ["view.theme", "file.save", "search.files", "view.focus"])
    }

    func testQueryDropsNonMatchesAndPrefersRecentOverAHigherScore() {
        let entries = sample()
        let plain = CommandRanking.ranked(entries: entries, query: "f", recent: [])
        XCTAssertEqual(plain.map(\.id), ["search.files", "view.focus"])
        let recent = CommandRanking.ranked(entries: entries, query: "s", recent: ["search.files"])
        XCTAssertEqual(recent.map(\.id), ["search.files", "file.save", "view.focus"])
    }

    func testEqualScoresKeepRegistrationOrder() {
        let entries = [
            CommandEntry(id: "a", name: "Save", category: "File"),
            CommandEntry(id: "b", name: "Save", category: "Edit"),
        ]
        let ranked = CommandRanking.ranked(entries: entries, query: "save", recent: [])
        XCTAssertEqual(ranked.map(\.id), ["a", "b"])
    }

    func testBindingsAreSearchable() {
        let entries = sample()
        XCTAssertEqual(CommandRanking.ranked(entries: entries, query: ":w", recent: []).map(\.id), ["file.save"])
        XCTAssertEqual(CommandRanking.ranked(entries: entries, query: "sf", recent: []).map(\.id), ["search.files"])
        XCTAssertEqual(CommandRanking.ranked(entries: entries, query: ":theme", recent: []).map(\.id), ["view.theme"])
    }

    func testCategoryMatchesOnlyOnceTheQueryIsSpecific() {
        let entries = sample()
        let short = CommandRanking.ranked(entries: entries, query: "vi", recent: [])
        XCTAssertEqual(short.map(\.id), [])
        let view = CommandRanking.ranked(entries: entries, query: "vie", recent: [])
        XCTAssertEqual(Set(view.map(\.id)), Set(["view.focus", "view.theme"]))
    }

    func testShortcutLabelPrefersTheMenuChord() {
        let save = sample()[0]
        XCTAssertEqual(CommandBinding.shortcutLabel(for: save.bindings), "\u{2318}S")
        let focus = sample()[2]
        XCTAssertEqual(CommandBinding.shortcutLabel(for: focus.bindings), "\u{2303}\u{2318}F")
        let theme = sample()[3]
        XCTAssertEqual(CommandBinding.shortcutLabel(for: theme.bindings), "\u{21E7}\u{2318}L")
        XCTAssertEqual(
            CommandBinding.shortcutLabel(for: [.init(.leader("sf")), .init(.ex("e"))]),
            "<leader>sf"
        )
        XCTAssertEqual(CommandBinding.shortcutLabel(for: [.init(.keys("-"))]), "-")
        XCTAssertEqual(CommandBinding.shortcutLabel(for: []), "")
    }

    func testRegisterRunAndEnabledPredicate() {
        MainActor.assumeIsolated {
            let registry = CommandRegistry()
            var ran: [String] = []
            registry.register(id: "file.save", name: "Save", category: "File", showsInMenu: true) { _ in
                ran.append("save")
            }
            registry.register(
                id: "edit.format",
                name: "Format Table",
                category: "Edit",
                enabled: { false }
            ) { _ in
                ran.append("format")
            }
            XCTAssertTrue(registry.isEnabled(id: "file.save"))
            XCTAssertFalse(registry.isEnabled(id: "edit.format"))
            XCTAssertFalse(registry.isEnabled(id: "missing"))
            XCTAssertTrue(registry.run(id: "file.save"))
            XCTAssertFalse(registry.run(id: "edit.format"))
            XCTAssertFalse(registry.run(id: "missing"))
            XCTAssertEqual(ran, ["save"])
            XCTAssertEqual(registry.ranked(matching: "").map(\.id), ["file.save", "edit.format"])
            XCTAssertEqual(registry.menuEntries(category: "File").map(\.id), ["file.save"])
            XCTAssertTrue(registry.menuEntries(category: "Edit").isEmpty)
        }
    }

    func testReregisterReplacesInPlace() {
        MainActor.assumeIsolated {
            let registry = CommandRegistry()
            registry.register(id: "file.save", name: "Save", category: "File") { _ in }
            registry.register(id: "file.open", name: "Open", category: "File") { _ in }
            registry.register(id: "file.save", name: "Save File", category: "File", showsInMenu: true) { _ in }
            XCTAssertEqual(registry.entries.map(\.id), ["file.save", "file.open"])
            XCTAssertEqual(registry.entries[0].name, "Save File")
            XCTAssertTrue(registry.entries[0].showsInMenu)
        }
    }

    func testRecordUseIgnoresUnknownIDs() {
        MainActor.assumeIsolated {
            let registry = CommandRegistry()
            registry.register(id: "a", name: "Alpha", category: "File") { _ in }
            registry.register(id: "b", name: "Beta", category: "File") { _ in }
            registry.recordUse(id: "missing")
            registry.recordUse(id: "b")
            XCTAssertEqual(registry.ranked(matching: "").map(\.id), ["b", "a"])
        }
    }

    func testExLookupIsExactThenUniquePrefix() {
        MainActor.assumeIsolated {
            let registry = CommandRegistry()
            registry.register(
                id: "file.save",
                name: "Save",
                category: "File",
                bindings: [.init(.ex("w")), .init(.ex("write"))]
            ) { _ in }
            registry.register(
                id: "file.close",
                name: "Close",
                category: "File",
                bindings: [.init(.ex("q")), .init(.ex("quit")), .init(.ex("wq"))]
            ) { _ in }
            XCTAssertEqual(registry.command(forEx: "w"), "file.save")
            XCTAssertEqual(registry.command(forEx: "write"), "file.save")
            XCTAssertEqual(registry.command(forEx: "wri"), "file.save")
            XCTAssertEqual(registry.command(forEx: "q"), "file.close")
            XCTAssertEqual(registry.command(forEx: "wq"), "file.close")
            XCTAssertEqual(registry.command(forEx: "wr"), "file.save")
            XCTAssertNil(registry.command(forEx: ""))
            XCTAssertNil(registry.command(forEx: "xyz"))
            registry.register(id: "view.theme", name: "Theme", category: "View", bindings: [.init(.ex("theme"))]) { _ in }
            registry.register(id: "edit.table", name: "Table", category: "Edit", bindings: [.init(.ex("table"))]) { _ in }
            XCTAssertNil(registry.command(forEx: "t"))
            XCTAssertEqual(registry.command(forEx: "th"), "view.theme")
        }
    }

    func testRunPassesArguments() {
        MainActor.assumeIsolated {
            let registry = CommandRegistry()
            var got = CommandArgs.none
            registry.register(id: "file.save", name: "Save", category: "File") { got = $0 }
            XCTAssertTrue(registry.run(id: "file.save", args: CommandArgs(text: "notes.md", lines: 1...3, bang: true)))
            XCTAssertEqual(got, CommandArgs(text: "notes.md", lines: 1...3, bang: true))
        }
    }

    func testKeymapUsesKeysLeaderAndTheWhenFilter() {
        MainActor.assumeIsolated {
            let registry = CommandRegistry()
            registry.register(
                id: "navigate.definition",
                name: "Go to Definition",
                category: "Navigate",
                bindings: [.init(.keys("gd")), .init(.chord(key: "d", command: true, shift: false, option: false, control: false))]
            ) { _ in }
            registry.register(
                id: "search.files",
                name: "Find Files",
                category: "Search",
                bindings: [.init(.leader("sf"))]
            ) { _ in }
            registry.register(
                id: "file.openEntry",
                name: "Open Entry",
                category: "File",
                bindings: [.init(.keys("<CR>"))]
            ) { _ in }
            let files = registry.keymap(leader: " ") { $0 != "file.openEntry" }
            XCTAssertEqual(files.lookup("gd"), .command("navigate.definition"))
            XCTAssertEqual(files.lookup("g"), .prefix)
            XCTAssertEqual(files.lookup(" sf"), .command("search.files"))
            XCTAssertEqual(files.lookup(" "), .prefix)
            XCTAssertEqual(files.lookup("<CR>"), .none)
            let directory = registry.keymap(leader: " ") { _ in true }
            XCTAssertEqual(directory.lookup("<CR>"), .command("file.openEntry"))
            XCTAssertEqual(directory.lookup("d"), .none)
        }
    }

    func testDisabledCommandIsLeftOutOfTheKeymap() {
        MainActor.assumeIsolated {
            let registry = CommandRegistry()
            registry.register(
                id: "file.openEntry",
                name: "Open Entry",
                category: "File",
                bindings: [.init(.keys("<CR>"))],
                enabled: { false }
            ) { _ in }
            XCTAssertEqual(registry.keymap(leader: " ") { _ in true }.lookup("<CR>"), .none)
        }
    }

    func testCollisionLastWinsAndReservedKeysAreDropped() {
        MainActor.assumeIsolated {
            let registry = CommandRegistry()
            var notes: [String] = []
            registry.onBindingCollision = { notes.append($0) }
            registry.register(id: "file.save", name: "Save", category: "File", bindings: [.init(.ex("w"))]) { _ in }
            registry.register(id: "other.save", name: "Other", category: "File", bindings: [.init(.ex("w"))]) { _ in }
            registry.register(id: "bad.motion", name: "Bad", category: "Edit", bindings: [.init(.keys("j")), .init(.keys("-"))]) { _ in }
            XCTAssertEqual(registry.command(forEx: "w"), "other.save")
            XCTAssertTrue(notes.contains { $0.contains("ex w") })
            XCTAssertTrue(notes.contains { $0.contains("keys j") })
            XCTAssertEqual(registry.keymap(leader: " ") { _ in true }.lookup("j"), .none)
            XCTAssertEqual(registry.keymap(leader: " ") { _ in true }.lookup("-"), .command("bad.motion"))
            XCTAssertFalse(registry.entries.first { $0.id == "bad.motion" }?.bindings.contains(.init(.keys("j"))) ?? true)
        }
    }

    func testRebindStealsALeaderSequence() {
        MainActor.assumeIsolated {
            let registry = CommandRegistry()
            registry.register(id: "search.grep", name: "Live Grep", category: "Search", bindings: [.init(.leader("sg"))]) { _ in }
            registry.register(id: "search.files", name: "Find Files", category: "Search", bindings: [.init(.leader("sf"))]) { _ in }
            XCTAssertFalse(registry.rebind(id: "missing", leader: "xx"))
            XCTAssertTrue(registry.rebind(id: "search.grep", leader: "xx"))
            XCTAssertTrue(registry.rebind(id: "search.grep", leader: "sf"))
            let grep = registry.entries.first { $0.id == "search.grep" }
            XCTAssertEqual(
                grep?.bindings.map(\.label),
                ["<leader>sg", "<leader>xx", "<leader>sf"]
            )
            let files = registry.entries.first { $0.id == "search.files" }
            XCTAssertEqual(files?.bindings, [])
            let map = registry.keymap(leader: " ") { _ in true }
            XCTAssertEqual(map.lookup(" sf"), .command("search.grep"))
            XCTAssertEqual(map.lookup(" xx"), .command("search.grep"))
            XCTAssertEqual(map.lookup(" sg"), .command("search.grep"))
        }
    }
}
