import Foundation
import QuillText

public enum LineEnding: Equatable, Sendable {
    case lf
    case crlf
    case mixed
}

public struct FileTypeSettings: Equatable, Sendable {
    public var languageId: String

    public init(languageId: String) {
        self.languageId = languageId
    }
}

public struct FileTypeRegistry: Equatable, Sendable {
    public var byExtension: [String: FileTypeSettings]
    public var byFilename: [String: FileTypeSettings]

    public init(
        byExtension: [String: FileTypeSettings] = FileTypeRegistry.defaults,
        byFilename: [String: FileTypeSettings] = [:]
    ) {
        self.byExtension = byExtension
        self.byFilename = byFilename
    }

    public static let defaults: [String: FileTypeSettings] = [
        "md": FileTypeSettings(languageId: "markdown"),
        "markdown": FileTypeSettings(languageId: "markdown"),
        "txt": FileTypeSettings(languageId: "plaintext"),
        "swift": FileTypeSettings(languageId: "swift"),
        "json": FileTypeSettings(languageId: "json"),
    ]

    public func settings(for url: URL) -> FileTypeSettings {
        let name = url.lastPathComponent
        if let named = byFilename[name] { return named }
        let ext = url.pathExtension.lowercased()
        return byExtension[ext] ?? FileTypeSettings(languageId: "plaintext")
    }

    public func languageId(for url: URL) -> String {
        settings(for: url).languageId
    }
}

public enum TextCodec {
    public struct Decoded: Equatable, Sendable {
        public var text: String
        public var ending: LineEnding
    }

    public enum Failure: Error, Equatable {
        case invalidUTF8
    }

    public static func decode(_ data: Data) throws -> Decoded {
        guard let text = String(data: data, encoding: .utf8) else {
            throw Failure.invalidUTF8
        }
        return Decoded(text: LineIndex.normalizingNewlines(text), ending: ending(of: text))
    }

    public static func encode(_ text: String, ending: LineEnding) -> Data {
        let stored: String
        switch ending {
        case .crlf:
            stored = text.replacingOccurrences(of: "\n", with: "\r\n")
        case .lf, .mixed:
            stored = text
        }
        return Data(stored.utf8)
    }

    public static func ending(of text: String) -> LineEnding {
        let crlf = text.contains("\r\n")
        let lf = text.replacingOccurrences(of: "\r\n", with: "").contains("\n")
        if crlf && lf { return .mixed }
        if crlf { return .crlf }
        return .lf
    }
}

public struct ExternalChange: Equatable, Sendable {
    public var modifiedAt: Date?

    public init(modifiedAt: Date?) {
        self.modifiedAt = modifiedAt
    }

    public static func conflicts(loaded: Date?, current: Date?) -> Bool {
        guard let loaded, let current else { return false }
        return current.timeIntervalSince(loaded) > 0.001
    }
}

public enum NavigationDecision: Equatable, Sendable {
    case allow
    case prompt(String)
}

public enum NavigationGuard {
    public static let unsavedMessage = "E37: No write since last change"

    public static func decide(isModified: Bool, force: Bool) -> NavigationDecision {
        if force || !isModified { return .allow }
        return .prompt(unsavedMessage)
    }
}
