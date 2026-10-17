import CoreFoundation
import Foundation

public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(_ any: Any) {
        // JSON numbers bridge to NSNumber, and `as Bool` succeeds for 0/1 on
        // both Darwin and Linux. Inspect CFBoolean before that cast so RPC ids
        // like `1` stay numbers instead of `true`.
        if any is NSNull {
            self = .null
            return
        }
        if let n = any as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
            return
        }
        if let b = any as? Bool {
            self = .bool(b)
            return
        }
        if let s = any as? String {
            self = .string(s)
            return
        }
        if let a = any as? [Any] {
            self = .array(a.map(JSONValue.init))
            return
        }
        if let d = any as? [String: Any] {
            self = .object(d.mapValues(JSONValue.init))
            return
        }
        if let d = any as? [AnyHashable: Any] {
            var obj: [String: JSONValue] = [:]
            for (k, v) in d {
                if let key = k as? String {
                    obj[key] = JSONValue(v)
                }
            }
            self = .object(obj)
            return
        }
        self = .null
    }

    public var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map(\.any)
        case .object(let o): return o.mapValues(\.any)
        }
    }

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var int: Int? {
        if case .number(let n) = self { return Int(n) }
        return nil
    }

    public var array: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var object: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        object?[key]
    }

    public static func encode(_ value: JSONValue) throws -> Data {
        try JSONSerialization.data(withJSONObject: value.any, options: [])
    }

    public static func decode(_ data: Data) throws -> JSONValue {
        let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return JSONValue(obj)
    }
}
