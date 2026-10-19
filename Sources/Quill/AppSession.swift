import Foundation
import QuillLSP
import QuillSearch
import QuillWorkspace

/// Process shelf: home, appearance, and the counters that are not the document,
/// the language-server link, or the prompt.
@MainActor
final class AppSession {
    let home: URL
    let isDark: @MainActor () -> Bool
    var appearanceObserver: NSKeyValueObservation?
    var closeRequests = 0
    var promptEpoch = 0
    var completionQuery: String?
    var completionGeneration = 0
    var hoverGeneration = 0
    var lspChain: Task<Void, Never>?
    let fileTypes = FileTypeRegistry()
    let servers = LanguageServerManager()
    let search = EditorSearch()
    var lspClientFactory: ((LSPServerConfig, URL) async throws -> LSPClient)?
    // quill-concurrency: JSON-RPC callbacks hop to the main actor before they touch the model.
    let hop = ModelHop()

    init(home: URL, isDark: @escaping @MainActor () -> Bool) {
        self.home = home
        self.isDark = isDark
    }
}

// quill-concurrency: The box only carries the model pointer across the JSON-RPC hop.
final class ModelHop: @unchecked Sendable {
    weak var model: AppModel?
}

@MainActor
final class EditorSearch {
    let session = SearchSession()
    let index = FileIndex()
    var grepTask: Task<Void, Never>?
    /// Tests pause the file index so Escape can win the race.
    var beforeIndex: @Sendable () async -> Void = {}
    var readPreview: @Sendable (URL) async -> String = { url in
        await Task.detached {
            (try? String(contentsOf: url, encoding: .utf8)).map { String($0.prefix(800)) } ?? ""
        }.value
    }
}
