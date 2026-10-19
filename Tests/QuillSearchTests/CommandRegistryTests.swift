import XCTest
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
            registry.register(id: "file.save", name: "Save", category: "File", showsInMenu: true) {
                ran.append("save")
            }
            registry.register(
                id: "edit.format",
                name: "Format Table",
                category: "Edit",
                enabled: { false }
            ) {
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
            registry.register(id: "file.save", name: "Save", category: "File") {}
            registry.register(id: "file.open", name: "Open", category: "File") {}
            registry.register(id: "file.save", name: "Save File", category: "File", showsInMenu: true) {}
            XCTAssertEqual(registry.entries.map(\.id), ["file.save", "file.open"])
            XCTAssertEqual(registry.entries[0].name, "Save File")
            XCTAssertTrue(registry.entries[0].showsInMenu)
        }
    }

    func testRecordUseIgnoresUnknownIDs() {
        MainActor.assumeIsolated {
            let registry = CommandRegistry()
            registry.register(id: "a", name: "Alpha", category: "File") {}
            registry.register(id: "b", name: "Beta", category: "File") {}
            registry.recordUse(id: "missing")
            registry.recordUse(id: "b")
            XCTAssertEqual(registry.ranked(matching: "").map(\.id), ["b", "a"])
        }
    }
}
