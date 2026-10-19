import Foundation
import QuillTOML

/// Last runtime appearance, kept beside the config so a toggle survives the next launch
/// without rewriting `config.toml`.
enum ThemeMemory {
    static func url(home: URL) -> URL {
        home.appendingPathComponent(".config/quill/state.toml")
    }

    static func load(from url: URL) -> ThemeChoice? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let parsed = try? TOML.parse(text),
              case .table(let table) = parsed,
              case .string(let raw) = table["theme"] else { return nil }
        return ThemeChoice.parse(raw)
    }

    static func save(_ choice: ThemeChoice, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "theme = \"\(choice.rawValue)\"\n".write(to: url, atomically: true, encoding: .utf8)
    }
}
