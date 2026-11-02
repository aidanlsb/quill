import Foundation
import QuillTOML
import QuillWorkspace

/// Last runtime appearance and browse folder, kept beside the config so a
/// toggle or last-used directory survives the next launch without rewriting
/// `config.toml`.
struct SessionState: Equatable {
    var theme: ThemeChoice?
    var lastDirectory: URL?

    static func url(home: URL) -> URL {
        home.appendingPathComponent(".config/quill/state.toml")
    }

    static func load(from url: URL) -> SessionState {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let parsed = try? TOML.parse(text),
              case .table(let table) = parsed else { return SessionState() }
        let theme: ThemeChoice?
        if case .string(let raw) = table["theme"] {
            theme = ThemeChoice.parse(raw)
        } else {
            theme = nil
        }
        let lastDirectory: URL?
        if case .string(let path) = table["lastDirectory"], !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            lastDirectory = BrowseRoot.isUsable(url) ? url.standardizedFileURL : nil
        } else {
            lastDirectory = nil
        }
        return SessionState(theme: theme, lastDirectory: lastDirectory)
    }

    static func save(_ state: SessionState, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var table: [String: TOMLValue] = [:]
        if let theme = state.theme {
            table["theme"] = .string(theme.rawValue)
        }
        if let directory = state.lastDirectory, BrowseRoot.isUsable(directory) {
            table["lastDirectory"] = .string(directory.standardizedFileURL.path)
        }
        try AtomicFile.write(Data(TOML.encode(.table(table)).utf8), to: url)
    }
}

enum ThemeMemory {
    static func url(home: URL) -> URL {
        SessionState.url(home: home)
    }

    static func load(from url: URL) -> ThemeChoice? {
        SessionState.load(from: url).theme
    }

    static func save(_ choice: ThemeChoice, to url: URL) throws {
        var state = SessionState.load(from: url)
        state.theme = choice
        try SessionState.save(state, to: url)
    }
}
