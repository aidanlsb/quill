import Foundation

/// The TOML subset Quill's config uses: tables, strings, ints, floats, bools,
/// arrays, inline tables, and arrays of tables. No dates and no multiline strings.
public enum TOMLValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([TOMLValue])
    case table([String: TOMLValue])
}

public struct TOMLParseError: Error, Equatable, CustomStringConvertible, LocalizedError, Sendable {
    public var line: Int
    public var message: String

    public var description: String { "TOML line \(line): \(message)" }
    public var errorDescription: String? { description }
}

public enum ConfigFileChoice: Equatable, Sendable {
    case toml
    case migrateJSON
    case none

    /// A toml file wins. JSON is only a one-time source when no toml exists yet.
    public static func choose(tomlExists: Bool, jsonExists: Bool) -> ConfigFileChoice {
        if tomlExists { return .toml }
        if jsonExists { return .migrateJSON }
        return .none
    }
}

public enum TOML {
    public static let maxBytes = 1_048_576
    public static let maxDepth = 32

    public static func parse(_ text: String) throws -> TOMLValue {
        if text.utf8.count > maxBytes {
            throw TOMLParseError(line: 1, message: "config is too large")
        }
        var parser = Parser(text: text)
        return try parser.parseDocument()
    }

    /// Stable, comment-free document. Nested scalar tables become `[sections]`.
    /// Arrays of tables become `[[sections]]`. Tables inside those elements stay inline.
    public static func encode(_ value: TOMLValue) -> String {
        guard case .table(let table) = value else { return encodeInline(value) + "\n" }
        let rendered = render(table, path: [], kind: .root)
        if rendered.isEmpty { return "\n" }
        return rendered.hasSuffix("\n") ? rendered : rendered + "\n"
    }

    private enum RenderKind {
        case root
        case section
        case element
    }

    private static func render(_ table: [String: TOMLValue], path: [String], kind: RenderKind) -> String {
        var direct = ""
        var later: [(String, TOMLValue)] = []
        for key in table.keys.sorted() {
            guard let value = table[key] else { continue }
            if isDirect(value, kind: kind) {
                direct += "\(encodeKey(key)) = \(encodeInline(value))\n"
            } else {
                later.append((key, value))
            }
        }
        var out = ""
        if kind == .section, !direct.isEmpty || later.isEmpty {
            out += "[\(path.map(encodeKey).joined(separator: "."))]\n"
        }
        out += direct
        for (key, value) in later {
            let child = path + [key]
            if !out.isEmpty && !out.hasSuffix("\n\n") { out += "\n" }
            switch value {
            case .table(let nested):
                out += render(nested, path: child, kind: .section)
            case .array(let items):
                for item in items {
                    guard case .table(let nested) = item else { continue }
                    out += "[[\(child.map(encodeKey).joined(separator: "."))]]\n"
                    out += render(nested, path: child, kind: .element)
                    if !out.hasSuffix("\n\n") { out += "\n" }
                }
            default:
                break
            }
        }
        return out
    }

    private static func isDirect(_ value: TOMLValue, kind: RenderKind) -> Bool {
        switch value {
        case .string, .int, .double, .bool:
            return true
        case .array(let items):
            return !items.contains { if case .table = $0 { return true }; return false }
        case .table(let nested):
            if nested.isEmpty { return true }
            if kind == .element {
                return nested.values.allSatisfy { isDirect($0, kind: .root) }
            }
            return false
        }
    }

    private static func encodeInline(_ value: TOMLValue) -> String {
        switch value {
        case .string(let text):
            return encodeString(text)
        case .int(let number):
            return String(number)
        case .double(let number):
            return String(number)
        case .bool(let flag):
            return flag ? "true" : "false"
        case .array(let items):
            return "[" + items.map(encodeInline).joined(separator: ", ") + "]"
        case .table(let table):
            let pairs = table.keys.sorted().compactMap { key -> String? in
                guard let item = table[key] else { return nil }
                return "\(encodeKey(key)) = \(encodeInline(item))"
            }
            if pairs.isEmpty { return "{}" }
            return "{ " + pairs.joined(separator: ", ") + " }"
        }
    }

    private static func encodeKey(_ key: String) -> String {
        let bare = key.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return (value >= 65 && value <= 90) || (value >= 97 && value <= 122)
                || (value >= 48 && value <= 57) || value == 95 || value == 45
        }
        if bare && !key.isEmpty { return key }
        return encodeString(key)
    }

    private static func encodeString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}

private struct Parser {
    let text: String
    var index: String.Index
    var line: Int
    var root: [String: TOMLValue] = [:]
    var context: Context = .root

    enum Context {
        case root
        case table([String])
        case element([String])
    }

    init(text: String) {
        self.text = text
        self.index = text.startIndex
        self.line = 1
    }

    mutating func parseDocument() throws -> TOMLValue {
        while true {
            skipTrivia()
            if done { break }
            if peek() == "[" {
                try parseHeader()
            } else {
                try parseKeyValue()
            }
        }
        return .table(root)
    }

    var done: Bool { index >= text.endIndex }

    func peek() -> Character? {
        done ? nil : text[index]
    }

    mutating func bump() -> Character? {
        guard !done else { return nil }
        let character = text[index]
        index = text.index(after: index)
        if character == "\n" { line += 1 }
        return character
    }

    func fail(_ message: String) -> TOMLParseError {
        TOMLParseError(line: line, message: message)
    }

    mutating func skipTrivia() {
        while let character = peek() {
            if character == " " || character == "\t" || character == "\n" || character == "\r" {
                _ = bump()
                continue
            }
            if character == "#" {
                while let next = peek(), next != "\n" { _ = bump() }
                continue
            }
            break
        }
    }

    mutating func skipSpaces() {
        while let character = peek(), character == " " || character == "\t" {
            _ = bump()
        }
    }

    mutating func parseHeader() throws {
        guard bump() == "[" else { throw fail("expected '['") }
        let array = peek() == "["
        if array { _ = bump() }
        skipTrivia()
        let path = try parseKeyPath()
        skipTrivia()
        guard bump() == "]" else { throw fail("expected ']'") }
        if array {
            guard bump() == "]" else { throw fail("expected ']]'") }
        }
        try finishLine()
        if path.isEmpty { throw fail("empty table name") }
        if array {
            root = try appendElement(root, path: path)
            context = .element(path)
        } else {
            root = try defineTable(root, path: path)
            context = .table(path)
        }
    }

    mutating func parseKeyValue() throws {
        let path = try parseKeyPath()
        skipTrivia()
        guard bump() == "=" else { throw fail("expected '='") }
        skipTrivia()
        let value = try parseValue(depth: 0)
        try finishLine()
        if path.isEmpty { throw fail("empty key") }
        switch context {
        case .root:
            root = try write(root, path: path, value: value)
        case .table(let prefix):
            root = try write(root, path: prefix + path, value: value)
        case .element(let arrayPath):
            root = try writeLast(root, arrayPath: arrayPath, path: path, value: value)
        }
    }

    mutating func finishLine() throws {
        skipSpaces()
        if peek() == "#" {
            while let next = peek(), next != "\n" { _ = bump() }
        }
        if let next = peek(), next != "\n" && next != "\r" {
            throw fail("unexpected \(next)")
        }
    }

    mutating func parseKeyPath() throws -> [String] {
        var path = [try parseKey()]
        while true {
            skipSpaces()
            guard peek() == "." else { break }
            _ = bump()
            skipSpaces()
            path.append(try parseKey())
        }
        if path.count > TOML.maxDepth { throw fail("key path is too deep") }
        return path
    }

    mutating func parseKey() throws -> String {
        if peek() == "\"" { return try parseBasicString() }
        if peek() == "'" { return try parseLiteralString() }
        guard let first = peek(), isBare(first) else { throw fail("expected a key") }
        var key = ""
        while let character = peek(), isBare(character) {
            key.append(character)
            _ = bump()
        }
        return key
    }

    func isBare(_ character: Character) -> Bool {
        if character.isLetter || character.isNumber { return true }
        return character == "_" || character == "-"
    }

    mutating func parseValue(depth: Int) throws -> TOMLValue {
        if depth > TOML.maxDepth { throw fail("nesting is too deep") }
        guard let character = peek() else { throw fail("expected a value") }
        switch character {
        case "\"": return .string(try parseBasicString())
        case "'": return .string(try parseLiteralString())
        case "[": return try parseArray(depth: depth + 1)
        case "{": return try parseInlineTable(depth: depth + 1)
        case "t", "f": return .bool(try parseBool())
        default: return try parseNumber()
        }
    }

    mutating func parseBasicString() throws -> String {
        let opened = line
        guard bump() == "\"" else { throw fail("expected '\"'") }
        var out = ""
        while let character = bump() {
            if character == "\"" { return out }
            if character == "\n" || character == "\r" {
                throw TOMLParseError(line: opened, message: "unterminated string")
            }
            if character != "\\" {
                out.append(character)
                continue
            }
            guard let escaped = bump() else { throw fail("unterminated string") }
            switch escaped {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "\\": out.append("\\")
            case "\"": out.append("\"")
            case "b": out.append("\u{8}")
            case "f": out.append("\u{c}")
            case "u": out.append(try unicode(digits: 4))
            case "U": out.append(try unicode(digits: 8))
            default: throw fail("bad escape \\\(escaped)")
            }
        }
        throw fail("unterminated string")
    }

    mutating func unicode(digits: Int) throws -> Character {
        var hex = ""
        for _ in 0..<digits {
            guard let character = bump(), character.isHexDigit else { throw fail("bad unicode escape") }
            hex.append(character)
        }
        guard let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) else {
            throw fail("bad unicode escape")
        }
        return Character(scalar)
    }

    mutating func parseLiteralString() throws -> String {
        let opened = line
        guard bump() == "'" else { throw fail("expected '''") }
        var out = ""
        while let character = bump() {
            if character == "'" { return out }
            if character == "\n" || character == "\r" {
                throw TOMLParseError(line: opened, message: "unterminated string")
            }
            out.append(character)
        }
        throw fail("unterminated string")
    }

    mutating func parseBool() throws -> Bool {
        if consumeWord("true") { return true }
        if consumeWord("false") { return false }
        throw fail("expected true or false")
    }

    mutating func consumeWord(_ word: String) -> Bool {
        var cursor = index
        for character in word {
            guard cursor < text.endIndex, text[cursor] == character else { return false }
            cursor = text.index(after: cursor)
        }
        if cursor < text.endIndex, isBare(text[cursor]) { return false }
        index = cursor
        return true
    }

    mutating func parseNumber() throws -> TOMLValue {
        let startLine = line
        var token = ""
        if peek() == "+" || peek() == "-" {
            token.append(bump()!)
        }
        guard let first = peek(), first.isNumber else { throw fail("expected a number") }
        token += try digits()
        var floating = false
        if peek() == "." {
            let afterDot = text.index(after: index)
            if afterDot < text.endIndex, text[afterDot].isNumber {
                token.append(bump()!)
                token += try digits()
                floating = true
            }
        }
        if peek() == "e" || peek() == "E" {
            token.append(bump()!)
            if peek() == "+" || peek() == "-" { token.append(bump()!) }
            token += try digits()
            floating = true
        }
        let plain = token.replacingOccurrences(of: "_", with: "")
        let numeric = plain.hasPrefix("+") ? String(plain.dropFirst()) : plain
        if floating {
            guard let number = Double(numeric) else { throw TOMLParseError(line: startLine, message: "bad float") }
            return .double(number)
        }
        guard let number = Int(numeric) else { throw TOMLParseError(line: startLine, message: "bad integer") }
        return .int(number)
    }

    mutating func digits() throws -> String {
        var out = ""
        while let character = peek(), character.isNumber || character == "_" {
            if character == "_" && (out.isEmpty || out.hasSuffix("_")) {
                throw fail("bad number")
            }
            out.append(character)
            _ = bump()
        }
        if out.hasSuffix("_") || out.isEmpty { throw fail("bad number") }
        return out
    }

    mutating func parseArray(depth: Int) throws -> TOMLValue {
        guard bump() == "[" else { throw fail("expected '['") }
        var items: [TOMLValue] = []
        while true {
            skipTrivia()
            if peek() == "]" {
                _ = bump()
                return .array(items)
            }
            items.append(try parseValue(depth: depth))
            skipTrivia()
            if peek() == "," {
                _ = bump()
                continue
            }
            if peek() == "]" {
                _ = bump()
                return .array(items)
            }
            throw fail("expected ',' or ']'")
        }
    }

    mutating func parseInlineTable(depth: Int) throws -> TOMLValue {
        guard bump() == "{" else { throw fail("expected '{'") }
        var table: [String: TOMLValue] = [:]
        while true {
            skipTrivia()
            if peek() == "}" {
                _ = bump()
                return .table(table)
            }
            let path = try parseKeyPath()
            skipTrivia()
            guard bump() == "=" else { throw fail("expected '='") }
            skipTrivia()
            let value = try parseValue(depth: depth)
            table = try write(table, path: path, value: value)
            skipTrivia()
            if peek() == "," {
                _ = bump()
                continue
            }
            if peek() == "}" {
                _ = bump()
                return .table(table)
            }
            throw fail("expected ',' or '}'")
        }
    }

    func write(_ table: [String: TOMLValue], path: [String], value: TOMLValue) throws -> [String: TOMLValue] {
        var table = table
        guard let head = path.first else { throw fail("empty key") }
        if path.count == 1 {
            if table[head] != nil { throw fail("duplicate key \(head)") }
            table[head] = value
            return table
        }
        let child: [String: TOMLValue]
        if let existing = table[head] {
            guard case .table(let nested) = existing else { throw fail("\(head) is not a table") }
            child = nested
        } else {
            child = [:]
        }
        table[head] = .table(try write(child, path: Array(path.dropFirst()), value: value))
        return table
    }

    func defineTable(_ table: [String: TOMLValue], path: [String]) throws -> [String: TOMLValue] {
        var table = table
        guard let head = path.first else { throw fail("empty table") }
        if path.count == 1 {
            if table[head] != nil { throw fail("duplicate table \(head)") }
            table[head] = .table([:])
            return table
        }
        let child: [String: TOMLValue]
        if let existing = table[head] {
            switch existing {
            case .table(let nested):
                child = nested
            case .array(let items):
                guard let last = items.last, case .table(let nested) = last else {
                    throw fail("\(head) is not a table")
                }
                var items = items
                items[items.count - 1] = .table(try defineTable(nested, path: Array(path.dropFirst())))
                table[head] = .array(items)
                return table
            default:
                throw fail("\(head) is not a table")
            }
        } else {
            child = [:]
        }
        table[head] = .table(try defineTable(child, path: Array(path.dropFirst())))
        return table
    }

    func appendElement(_ table: [String: TOMLValue], path: [String]) throws -> [String: TOMLValue] {
        var table = table
        guard let head = path.first else { throw fail("empty table") }
        if path.count == 1 {
            var items: [TOMLValue] = []
            if let existing = table[head] {
                guard case .array(let current) = existing else { throw fail("\(head) is not an array") }
                items = current
            }
            items.append(.table([:]))
            table[head] = .array(items)
            return table
        }
        if let existing = table[head] {
            switch existing {
            case .table(let nested):
                table[head] = .table(try appendElement(nested, path: Array(path.dropFirst())))
                return table
            case .array(let items):
                guard var items = Optional(items), let last = items.last, case .table(let nested) = last else {
                    throw fail("\(head) is not a table")
                }
                items[items.count - 1] = .table(try appendElement(nested, path: Array(path.dropFirst())))
                table[head] = .array(items)
                return table
            default:
                throw fail("\(head) is not a table")
            }
        }
        table[head] = .table(try appendElement([:], path: Array(path.dropFirst())))
        return table
    }

    func writeLast(
        _ table: [String: TOMLValue],
        arrayPath: [String],
        path: [String],
        value: TOMLValue
    ) throws -> [String: TOMLValue] {
        var table = table
        guard let head = arrayPath.first else { throw fail("empty table") }
        if arrayPath.count == 1 {
            guard case .array(var items) = table[head],
                  let last = items.last,
                  case .table(let nested) = last else {
                throw fail("\(head) is not an array of tables")
            }
            items[items.count - 1] = .table(try write(nested, path: path, value: value))
            table[head] = .array(items)
            return table
        }
        guard let existing = table[head] else { throw fail("missing \(head)") }
        switch existing {
        case .table(let nested):
            table[head] = .table(try writeLast(nested, arrayPath: Array(arrayPath.dropFirst()), path: path, value: value))
        case .array(var items):
            guard let last = items.last, case .table(let nested) = last else {
                throw fail("\(head) is not a table")
            }
            items[items.count - 1] = .table(
                try writeLast(nested, arrayPath: Array(arrayPath.dropFirst()), path: path, value: value)
            )
            table[head] = .array(items)
        default:
            throw fail("\(head) is not a table")
        }
        return table
    }
}
