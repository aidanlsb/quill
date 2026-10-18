import AppKit
import Foundation
import QuillLSP
import QuillTOML
import QuillVim

struct QuillConfig: Equatable {
    var leader: String
    var leaderMaps: [String: String]
    var shellCommands: [String: String]
    var lsp: LSPSettings
    var columnWidth: Int
    var fontSize: Double
    /// Family name for the body. Empty, or a family that is not installed, uses the system font.
    var font: String
    var theme: ThemeChoice
    var shiftWidth: Int

    static let `default` = QuillConfig(
        leader: " ",
        leaderMaps: ["sf": "findFiles", "sg": "liveGrep"],
        shellCommands: [:],
        lsp: LSPSettings(servers: []),
        columnWidth: QuillMetrics.defaultColumn,
        fontSize: QuillMetrics.defaultFontSize,
        font: "",
        theme: .system,
        shiftWidth: 2
    )

    static func load() -> QuillConfig {
        loadReporting().config
    }

    static func loadReporting() -> (config: QuillConfig, error: String?) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let toml = [
            home.appendingPathComponent(".config/quill/config.toml"),
            home.appendingPathComponent("Library/Application Support/Quill/config.toml"),
        ]
        let json = [
            home.appendingPathComponent(".config/quill/config.json"),
            home.appendingPathComponent("Library/Application Support/Quill/config.json"),
        ]
        let files = FileManager.default
        let tomlURL = toml.first(where: { files.fileExists(atPath: $0.path) })
        let jsonURL = json.first(where: { files.fileExists(atPath: $0.path) })
        switch ConfigFileChoice.choose(tomlExists: tomlURL != nil, jsonExists: jsonURL != nil) {
        case .toml:
            return loadFile(at: tomlURL!, decode: decodeTOML)
        case .migrateJSON:
            return migrate(json: jsonURL!, to: toml[0])
        case .none:
            return (.default, nil)
        }
    }

    /// TOML is the config format. JSON remains so an existing file can be copied once.
    static func decode(_ data: Data) throws -> QuillConfig {
        try decodeTOML(data)
    }

    static func decodeTOML(_ data: Data) throws -> QuillConfig {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConfigError("config is not UTF-8")
        }
        let value = try TOML.parse(text)
        guard case .table(let table) = value else {
            throw ConfigError("config root must be a table")
        }
        return try from(table: table)
    }

    static func decodeJSON(_ data: Data) throws -> QuillConfig {
        try JSONDecoder().decode(Stored.self, from: data).config
    }

    func tomlSource() -> String {
        TOML.encode(tomlValue())
    }

    private static func loadFile(at url: URL, decode: (Data) throws -> QuillConfig) -> (config: QuillConfig, error: String?) {
        do {
            return (try decode(Data(contentsOf: url)), nil)
        } catch {
            return (.default, "config: \(error.localizedDescription)")
        }
    }

    private static func migrate(json: URL, to toml: URL) -> (config: QuillConfig, error: String?) {
        let config: QuillConfig
        do {
            config = try decodeJSON(Data(contentsOf: json))
        } catch {
            return (.default, "config: \(error.localizedDescription)")
        }
        do {
            try FileManager.default.createDirectory(
                at: toml.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try config.tomlSource().write(to: toml, atomically: true, encoding: .utf8)
            return (config, "Migrated \(json.path) to \(toml.path). The JSON file was left in place.")
        } catch {
            return (config, "config: could not write \(toml.path) (\(error.localizedDescription))")
        }
    }

    private static func from(table: [String: TOMLValue]) throws -> QuillConfig {
        let leader = try string(table["leader"]) ?? QuillConfig.default.leader
        let maps = try stringTable(table["leaderMaps"]) ?? QuillConfig.default.leaderMaps
        let shells = try stringTable(table["shellCommands"]) ?? [:]
        let column = try int(table["columnWidth"]) ?? QuillConfig.default.columnWidth
        let fontSize = QuillMetrics.fontSize(try double(table["fontSize"]))
        let font = (try string(table["font"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let theme = try themeChoice(table["theme"]) ?? QuillConfig.default.theme
        let shift = try int(table["shiftWidth"]) ?? QuillConfig.default.shiftWidth
        return QuillConfig(
            leader: leader,
            leaderMaps: maps,
            shellCommands: shells,
            lsp: try lspSettings(table["lsp"]),
            columnWidth: column,
            fontSize: fontSize,
            font: font,
            theme: theme,
            shiftWidth: shift
        )
    }

    private static func lspSettings(_ value: TOMLValue?) throws -> LSPSettings {
        guard let value else { return QuillConfig.default.lsp }
        guard case .table(let table) = value else { throw ConfigError("lsp must be a table") }
        guard let servers = table["servers"] else { return LSPSettings(servers: []) }
        guard case .array(let items) = servers else { throw ConfigError("lsp.servers must be an array") }
        return LSPSettings(servers: try items.map(server))
    }

    private static func server(_ value: TOMLValue) throws -> LSPServerConfig {
        guard case .table(let table) = value else { throw ConfigError("lsp server must be a table") }
        guard let name = try string(table["name"]), !name.isEmpty else { throw ConfigError("lsp server needs a name") }
        guard let command = try string(table["command"]), !command.isEmpty else {
            throw ConfigError("lsp server \(name) needs a command")
        }
        return LSPServerConfig(
            name: name,
            command: command,
            arguments: try stringArray(table["arguments"]) ?? [],
            extensions: try stringArray(table["extensions"]) ?? [".md", ".markdown"],
            languages: try stringArray(table["languages"]) ?? ["markdown"],
            rootMarkers: try stringArray(table["rootMarkers"]) ?? [".git"],
            env: try stringTable(table["env"]) ?? [:]
        )
    }

    private static func themeChoice(_ value: TOMLValue?) throws -> ThemeChoice? {
        guard let value else { return nil }
        guard case .string(let text) = value, let choice = ThemeChoice.parse(text) else {
            throw ConfigError("theme must be system, light, or dark")
        }
        return choice
    }

    private static func string(_ value: TOMLValue?) throws -> String? {
        guard let value else { return nil }
        guard case .string(let text) = value else { throw ConfigError("expected a string") }
        return text
    }

    private static func int(_ value: TOMLValue?) throws -> Int? {
        guard let value else { return nil }
        switch value {
        case .int(let number): return number
        case .double(let number) where number.rounded() == number: return Int(number)
        default: throw ConfigError("expected an integer")
        }
    }

    private static func double(_ value: TOMLValue?) throws -> Double? {
        guard let value else { return nil }
        switch value {
        case .double(let number): return number
        case .int(let number): return Double(number)
        default: throw ConfigError("expected a number")
        }
    }

    private static func stringArray(_ value: TOMLValue?) throws -> [String]? {
        guard let value else { return nil }
        guard case .array(let items) = value else { throw ConfigError("expected an array of strings") }
        return try items.map { item in
            guard case .string(let text) = item else { throw ConfigError("expected an array of strings") }
            return text
        }
    }

    private static func stringTable(_ value: TOMLValue?) throws -> [String: String]? {
        guard let value else { return nil }
        guard case .table(let table) = value else { throw ConfigError("expected a table of strings") }
        var out: [String: String] = [:]
        for (key, item) in table {
            guard case .string(let text) = item else { throw ConfigError("expected a table of strings") }
            out[key] = text
        }
        return out
    }

    private func tomlValue() -> TOMLValue {
        var table: [String: TOMLValue] = [
            "leader": .string(leader),
            "leaderMaps": .table(leaderMaps.mapValues { .string($0) }),
            "shellCommands": .table(shellCommands.mapValues { .string($0) }),
            "columnWidth": .int(columnWidth),
            "font": .string(font),
            "theme": .string(theme.rawValue),
            "shiftWidth": .int(shiftWidth),
        ]
        if fontSize.rounded() == fontSize {
            table["fontSize"] = .int(Int(fontSize))
        } else {
            table["fontSize"] = .double(fontSize)
        }
        let servers = lsp.servers.map { server -> TOMLValue in
            .table([
                "name": .string(server.name),
                "command": .string(server.command),
                "arguments": .array(server.arguments.map { .string($0) }),
                "extensions": .array(server.extensions.map { .string($0) }),
                "languages": .array(server.languages.map { .string($0) }),
                "rootMarkers": .array(server.rootMarkers.map { .string($0) }),
                "env": .table(server.env.mapValues { .string($0) }),
            ])
        }
        table["lsp"] = .table(["servers": .array(servers)])
        return .table(table)
    }

    private struct Stored: Decodable {
        var config: QuillConfig
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let leader = try c.decodeIfPresent(String.self, forKey: .leader) ?? QuillConfig.default.leader
            let maps = try c.decodeIfPresent([String: String].self, forKey: .leaderMaps) ?? QuillConfig.default.leaderMaps
            let shells = try c.decodeIfPresent([String: String].self, forKey: .shellCommands) ?? [:]
            let lsp = try c.decodeIfPresent(LSPSettings.self, forKey: .lsp) ?? QuillConfig.default.lsp
            let column = try c.decodeIfPresent(Int.self, forKey: .columnWidth) ?? QuillConfig.default.columnWidth
            let fontSize = QuillMetrics.fontSize(try c.decodeIfPresent(Double.self, forKey: .fontSize))
            let font = (try c.decodeIfPresent(String.self, forKey: .font) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let theme = ThemeChoice.parse(try c.decodeIfPresent(String.self, forKey: .theme) ?? "") ?? .system
            let shift = try c.decodeIfPresent(Int.self, forKey: .shiftWidth) ?? QuillConfig.default.shiftWidth
            config = QuillConfig(
                leader: leader,
                leaderMaps: maps,
                shellCommands: shells,
                lsp: lsp,
                columnWidth: column,
                fontSize: fontSize,
                font: font,
                theme: theme,
                shiftWidth: shift
            )
        }

        enum CodingKeys: String, CodingKey {
            case leader, leaderMaps, shellCommands, lsp, columnWidth, fontSize, font, theme, shiftWidth
        }
    }

    func apply(to engine: Engine) {
        if let ch = leader.first {
            engine.leaderKey = ch
        }
        engine.shiftWidth = shiftWidth
        // Overlay config onto the engine defaults so `ca` survives a config that only lists sf/sg.
        var maps = engine.leaderBindings
        for (seq, name) in leaderMaps {
            maps[seq] = Self.action(named: name)
        }
        for (seq, command) in shellCommands where !seq.isEmpty && !command.isEmpty {
            maps[seq] = .shell(command)
        }
        engine.leaderBindings = maps
    }

    private static func action(named name: String) -> HostAction {
        switch name {
        case "findFiles": return .findFiles
        case "liveGrep": return .liveGrep
        case "codeAction": return .codeAction
        case "findReferences": return .findReferences
        case "goToDefinition": return .goToDefinition
        case "toggleTheme": return .toggleTheme
        default: return .command(name)
        }
    }
}

private struct ConfigError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// System pasteboard adapter. The engine only reads and writes this from the
/// app's main-actor event loop. The assumeIsolated hop uses static helpers so
/// it does not capture a non-Sendable `self`.
// quill-concurrency: Clipboard methods hop with assumeIsolated and run on the main actor only.
final class PasteboardClipboard: Clipboard, @unchecked Sendable {
    var text: String {
        get {
            MainActor.assumeIsolated {
                Self.readPasteboard()
            }
        }
        set {
            let value = newValue
            MainActor.assumeIsolated {
                Self.writePasteboard(value)
            }
        }
    }

    @MainActor
    private static func readPasteboard() -> String {
        NSPasteboard.general.string(forType: .string) ?? ""
    }

    @MainActor
    private static func writePasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
