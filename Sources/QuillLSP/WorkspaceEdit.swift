import Foundation
import QuillText

public struct LSPTextEdit: Equatable, Sendable {
    public var range: LSPRange
    public var newText: String

    public init(range: LSPRange, newText: String) {
        self.range = range
        self.newText = newText
    }

    public static func from(_ value: JSONValue) -> LSPTextEdit? {
        guard let object = value.object,
              let range = object["range"].flatMap(LSPRange.from),
              let newText = object["newText"]?.string else { return nil }
        return LSPTextEdit(range: range, newText: newText)
    }
}

/// One UTF-16 edit against the buffer the engine already has open.
public struct BufferEdit: Equatable, Sendable {
    public var range: Range<Int>
    public var replacement: String

    public init(range: Range<Int>, replacement: String) {
        self.range = range
        self.replacement = replacement
    }
}

/// LSP `WorkspaceEdit`: a `changes` map and/or `documentChanges` text edits.
/// Create/rename/delete operations are recorded so the host can say they were not applied.
public struct WorkspaceEdit: Equatable, Sendable {
    public enum DocumentChange: Equatable, Sendable {
        case text(uri: String, edits: [LSPTextEdit])
        case other
    }

    public var changes: [String: [LSPTextEdit]]
    public var documentChanges: [DocumentChange]

    public init(changes: [String: [LSPTextEdit]] = [:], documentChanges: [DocumentChange] = []) {
        self.changes = changes
        self.documentChanges = documentChanges
    }

    public static func parse(_ value: JSONValue) -> WorkspaceEdit {
        var changes: [String: [LSPTextEdit]] = [:]
        if let map = value.object?["changes"]?.object {
            for (uri, raw) in map {
                changes[uri] = raw.array?.compactMap(LSPTextEdit.from) ?? []
            }
        }
        var documentChanges: [DocumentChange] = []
        if let items = value.object?["documentChanges"]?.array {
            for item in items {
                if let uri = item.object?["textDocument"]?.object?["uri"]?.string {
                    let edits = item.object?["edits"]?.array?.compactMap(LSPTextEdit.from) ?? []
                    documentChanges.append(.text(uri: uri, edits: edits))
                } else {
                    documentChanges.append(.other)
                }
            }
        }
        return WorkspaceEdit(changes: changes, documentChanges: documentChanges)
    }

    /// Edits for `file`, in end-to-start order, so applying them in sequence stays valid.
    public func bufferEdits(in text: String, file: URL) -> [BufferEdit] {
        var collected: [LSPTextEdit] = []
        for (uri, edits) in changes where Self.matches(uri: uri, file: file) {
            collected.append(contentsOf: edits)
        }
        for change in documentChanges {
            if case .text(let uri, let edits) = change, Self.matches(uri: uri, file: file) {
                collected.append(contentsOf: edits)
            }
        }
        let lines = LineIndex(text)
        let mapped = collected.map { edit -> BufferEdit in
            let start = lines.offset(of: edit.range.start.textPosition)
            let end = lines.offset(of: edit.range.end.textPosition)
            let lower = min(start, end)
            let upper = max(start, end)
            return BufferEdit(range: lower..<upper, replacement: edit.newText)
        }
        return mapped.sorted { lhs, rhs in
            if lhs.range.lowerBound != rhs.range.lowerBound {
                return lhs.range.lowerBound > rhs.range.lowerBound
            }
            return lhs.range.upperBound > rhs.range.upperBound
        }
    }

    /// Text edits for a different file, or a create/rename/delete the editor does not apply.
    public func containsEdits(outside file: URL) -> Bool {
        if changes.contains(where: { uri, edits in
            !edits.isEmpty && !Self.matches(uri: uri, file: file)
        }) {
            return true
        }
        for change in documentChanges {
            switch change {
            case .other:
                return true
            case .text(let uri, let edits):
                if !edits.isEmpty && !Self.matches(uri: uri, file: file) { return true }
            }
        }
        return false
    }

    public static func matches(uri: String, file: URL) -> Bool {
        guard let path = FileURI.localPath(from: uri) else { return false }
        return path == file.standardizedFileURL.path
    }
}

public struct LSPCommand: Equatable, Sendable {
    public var title: String
    public var command: String
    public var arguments: JSONValue?

    public init(title: String, command: String, arguments: JSONValue? = nil) {
        self.title = title
        self.command = command
        self.arguments = arguments
    }
}

/// One entry from `textDocument/codeAction`: a literal `CodeAction` or a `Command`.
public struct CodeAction: Equatable, Sendable {
    public var title: String
    public var kind: String?
    public var edit: WorkspaceEdit?
    public var command: LSPCommand?
    public var isPreferred: Bool

    public init(
        title: String,
        kind: String? = nil,
        edit: WorkspaceEdit? = nil,
        command: LSPCommand? = nil,
        isPreferred: Bool = false
    ) {
        self.title = title
        self.kind = kind
        self.edit = edit
        self.command = command
        self.isPreferred = isPreferred
    }

    public static func list(from value: JSONValue) -> [CodeAction] {
        value.array?.compactMap(CodeAction.from) ?? []
    }

    public static func from(_ value: JSONValue) -> CodeAction? {
        guard let object = value.object else { return nil }
        if let name = object["command"]?.string {
            let title = object["title"]?.string ?? name
            return CodeAction(
                title: title,
                command: LSPCommand(title: title, command: name, arguments: object["arguments"])
            )
        }
        let title = object["title"]?.string ?? ""
        let edit = object["edit"].map(WorkspaceEdit.parse)
        var command: LSPCommand?
        if let nested = object["command"]?.object, let name = nested["command"]?.string {
            command = LSPCommand(
                title: nested["title"]?.string ?? name,
                command: name,
                arguments: nested["arguments"]
            )
        }
        if title.isEmpty, edit == nil, command == nil { return nil }
        return CodeAction(
            title: title,
            kind: object["kind"]?.string,
            edit: edit,
            command: command,
            isPreferred: object["isPreferred"]?.bool ?? false
        )
    }
}

extension LSPRange {
    var json: JSONValue {
        .object(["start": start.json, "end": end.json])
    }
}

extension Diagnostic {
    var json: JSONValue {
        var object: [String: JSONValue] = [
            "range": range.json,
            "severity": .number(Double(severity)),
            "message": .string(message),
        ]
        if let code {
            object["code"] = .string(code)
        }
        return .object(object)
    }
}
