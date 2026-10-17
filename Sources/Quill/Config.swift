import AppKit
import Foundation
import QuillLSP
import QuillVim

struct QuillConfig: Equatable {
    var leader: String
    var leaderMaps: [String: String]
    var lsp: LSPSettings
    var columnWidth: Int
    var shiftWidth: Int

    static let `default` = QuillConfig(
        leader: " ",
        leaderMaps: ["sf": "findFiles", "sg": "liveGrep"],
        lsp: LSPSettings(servers: []),
        columnWidth: 76,
        shiftWidth: 2
    )

    static func load() -> QuillConfig {
        loadReporting().config
    }

    static func loadReporting() -> (config: QuillConfig, error: String?) {
        let urls = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/quill/config.json"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Quill/config.json"),
        ]
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                let decoded = try JSONDecoder().decode(Stored.self, from: data)
                return (decoded.config, nil)
            } catch {
                return (.default, "config: \(error.localizedDescription)")
            }
        }
        return (.default, nil)
    }

    private struct Stored: Decodable {
        var config: QuillConfig
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let leader = try c.decodeIfPresent(String.self, forKey: .leader) ?? QuillConfig.default.leader
            let maps = try c.decodeIfPresent([String: String].self, forKey: .leaderMaps) ?? QuillConfig.default.leaderMaps
            let lsp = try c.decodeIfPresent(LSPSettings.self, forKey: .lsp) ?? QuillConfig.default.lsp
            let column = try c.decodeIfPresent(Int.self, forKey: .columnWidth) ?? QuillConfig.default.columnWidth
            let shift = try c.decodeIfPresent(Int.self, forKey: .shiftWidth) ?? QuillConfig.default.shiftWidth
            config = QuillConfig(leader: leader, leaderMaps: maps, lsp: lsp, columnWidth: column, shiftWidth: shift)
        }

        enum CodingKeys: String, CodingKey {
            case leader, leaderMaps, lsp, columnWidth, shiftWidth
        }
    }

    func apply(to engine: Engine) {
        if let ch = leader.first {
            engine.leaderKey = ch
        }
        engine.shiftWidth = shiftWidth
        var maps: [String: HostAction] = [:]
        for (seq, name) in leaderMaps {
            switch name {
            case "findFiles": maps[seq] = .findFiles
            case "liveGrep": maps[seq] = .liveGrep
            default: maps[seq] = .command(name)
            }
        }
        if !maps.isEmpty {
            engine.leaderBindings = maps
        }
    }
}

/// System pasteboard adapter. `@unchecked Sendable` because the engine only
/// reads/writes this from the app's main-actor event loop (key handlers / host
/// actions). The assumeIsolated hop uses static helpers so it does not capture
/// a non-Sendable `self`.
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
