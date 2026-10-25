import XCTest
@testable import QuillTOML

final class TOMLTests: XCTestCase {
    func testScalarsCommentsAndNumbers() throws {
        let value = try TOML.parse("""
        # comment
        leader = " "
        columnWidth = 70
        fontSize = 16.5
        shiftWidth = +2
        enabled = true
        off = false
        note = 'raw\\n'
        escaped = "a\\n\\"b\\""
        """)
        XCTAssertEqual(value["leader"], .string(" "))
        XCTAssertEqual(value["columnWidth"], .int(70))
        XCTAssertEqual(value["fontSize"], .double(16.5))
        XCTAssertEqual(value["shiftWidth"], .int(2))
        XCTAssertEqual(value["enabled"], .bool(true))
        XCTAssertEqual(value["off"], .bool(false))
        XCTAssertEqual(value["note"], .string("raw\\n"))
        XCTAssertEqual(value["escaped"], .string("a\n\"b\""))
    }

    func testInlineTablesAndArrays() throws {
        let value = try TOML.parse("""
        shellCommands = { d = "rvn daily", x = "echo hi" }
        arguments = ["lsp", "server",]
        lsp = { servers = [
          { name = "marksman", command = "marksman", arguments = ["server"], env = { TERM = "xterm" } }
        ] }
        """)
        XCTAssertEqual(value["shellCommands"]?["d"], .string("rvn daily"))
        XCTAssertEqual(value["arguments"], .array([.string("lsp"), .string("server")]))
        XCTAssertEqual(value["lsp"]?["servers"], .array([
            .table([
                "name": .string("marksman"),
                "command": .string("marksman"),
                "arguments": .array([.string("server")]),
                "env": .table(["TERM": .string("xterm")]),
            ]),
        ]))
    }

    func testArrayOfTables() throws {
        let value = try TOML.parse("""
        [[lsp.servers]]
        name = "marksman"
        command = "marksman"
        arguments = ["server"]

        [[lsp.servers]]
        name = "rvn"
        command = "rvn"
        env = { A = "1" }
        """)
        guard case .array(let servers) = value["lsp"]?["servers"] else {
            return XCTFail("servers missing")
        }
        XCTAssertEqual(servers.count, 2)
        XCTAssertEqual(servers[0]["name"], .string("marksman"))
        XCTAssertEqual(servers[0]["arguments"], .array([.string("server")]))
        XCTAssertEqual(servers[1]["env"]?["A"], .string("1"))
    }

    func testExampleConfigParses() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("examples/config.toml")
        let text = try String(contentsOf: url, encoding: .utf8)
        let value = try TOML.parse(text)
        XCTAssertEqual(value["leader"], .string(" "))
        XCTAssertEqual(value["columnWidth"], .int(70))
        XCTAssertEqual(value["fontSize"], .int(16))
        XCTAssertEqual(value["font"], .string(""))
        XCTAssertEqual(value["leaderMaps"]?["sf"], .string("search.files"))
        XCTAssertEqual(value["shellCommands"]?["d"], .string("rvn daily"))
        guard case .array(let servers) = value["lsp"]?["servers"] else {
            return XCTFail("example servers missing")
        }
        XCTAssertEqual(servers.count, 2)
        XCTAssertEqual(servers[0]["command"], .string("marksman"))
        XCTAssertEqual(servers[0]["rootMarkers"], .array([.string(".git"), .string(".marksman.toml")]))
        XCTAssertEqual(servers[1]["arguments"], .array([.string("lsp")]))
    }

    func testEncodeRoundTrip() throws {
        let original = try TOML.parse("""
        leader = " "
        fontSize = 16
        [leaderMaps]
        sf = "findFiles"
        [shellCommands]
        d = "rvn daily"
        [[lsp.servers]]
        name = "marksman"
        command = "marksman"
        arguments = ["server"]
        env = { TERM = "xterm" }
        """)
        let again = try TOML.parse(TOML.encode(original))
        XCTAssertEqual(again["leader"], .string(" "))
        XCTAssertEqual(again["fontSize"], .int(16))
        XCTAssertEqual(again["leaderMaps"]?["sf"], .string("findFiles"))
        XCTAssertEqual(again["shellCommands"]?["d"], .string("rvn daily"))
        XCTAssertEqual(again["lsp"]?["servers"]?[0]?["command"], .string("marksman"))
        XCTAssertEqual(again["lsp"]?["servers"]?[0]?["env"]?["TERM"], .string("xterm"))
    }

    func testReportsTheLineOfABadString() {
        XCTAssertThrowsError(try TOML.parse("ok = 1\nbad = \"unterminated\n")) { error in
            let parsed = error as? TOMLParseError
            XCTAssertEqual(parsed?.line, 2)
            XCTAssertEqual(parsed?.message, "unterminated string")
        }
    }

    func testRejectsDeepNestingAndHugeDocuments() {
        let deep = "a = " + String(repeating: "[", count: 40) + "1" + String(repeating: "]", count: 40)
        XCTAssertThrowsError(try TOML.parse(deep)) { error in
            XCTAssertEqual((error as? TOMLParseError)?.message, "nesting is too deep")
        }
        let huge = "a = \"" + String(repeating: "x", count: TOML.maxBytes) + "\""
        XCTAssertThrowsError(try TOML.parse(huge)) { error in
            XCTAssertEqual((error as? TOMLParseError)?.message, "config is too large")
        }
    }

    func testTomlWinsOverJSON() {
        XCTAssertEqual(ConfigFileChoice.choose(tomlExists: true, jsonExists: true), .toml)
        XCTAssertEqual(ConfigFileChoice.choose(tomlExists: false, jsonExists: true), .migrateJSON)
        XCTAssertEqual(ConfigFileChoice.choose(tomlExists: false, jsonExists: false), .none)
    }
}

private extension TOMLValue {
    subscript(key: String) -> TOMLValue? {
        if case .table(let table) = self { return table[key] }
        return nil
    }

    subscript(index: Int) -> TOMLValue? {
        if case .array(let items) = self, items.indices.contains(index) { return items[index] }
        return nil
    }
}
