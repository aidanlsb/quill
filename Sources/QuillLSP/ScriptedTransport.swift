import Foundation

/// Same-process JSON-RPC endpoint: writes are answered on the same object,
/// so tests do not need a second thread talking through a pipe pair.
public final class ScriptedTransport: ByteTransport, @unchecked Sendable {
    public var onRequest: (String, JSONValue?) -> JSONValue = { _, _ in .null }
    public var onNotify: (String, JSONValue?) -> Void = { _, _ in }

    private let inbound = JSONRPCFramer()
    private let outbound = JSONRPCFramer()
    private let condition = NSCondition()
    private var replies: [Data] = []
    private var closed = false

    public init() {}

    public func write(_ data: Data) throws {
        for payload in inbound.append(data) {
            guard let value = try? JSONValue.decode(payload), let obj = value.object else { continue }
            let method = obj["method"]?.string ?? ""
            let params = obj["params"]
            if let idVal = obj["id"] {
                let id = idVal.int ?? 0
                let result = onRequest(method, params)
                let encoded = try JSONValue.encode(.object([
                    "jsonrpc": .string("2.0"),
                    "id": .number(Double(id)),
                    "result": result,
                ]))
                condition.lock()
                replies.append(outbound.encode(encoded))
                condition.signal()
                condition.unlock()
            } else {
                onNotify(method, params)
            }
        }
    }

    public func readSome() throws -> Data? {
        condition.lock()
        defer { condition.unlock() }
        while replies.isEmpty && !closed {
            condition.wait()
        }
        if replies.isEmpty { return nil }
        return replies.removeFirst()
    }

    public func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    /// Inject an unsolicited server notification (diagnostics, log, …).
    public func pushNotification(method: String, params: JSONValue? = nil) throws {
        var obj: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
        ]
        if let params { obj["params"] = params }
        let encoded = try JSONValue.encode(.object(obj))
        condition.lock()
        replies.append(outbound.encode(encoded))
        condition.signal()
        condition.unlock()
    }
}
