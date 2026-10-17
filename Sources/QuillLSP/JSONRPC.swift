import Foundation

public enum JSONRPCError: Error, Equatable {
    case parse(String)
    case timeout
    case closed
    case serverUnavailable(String)
    case response(code: Int, message: String)
}

/// LSP / JSON-RPC 2.0 header framing (`Content-Length: N\r\n\r\n{json}`).
public final class JSONRPCFramer: @unchecked Sendable {
    private var buffer = Data()

    public init() {}

    public func encode(_ payload: Data) -> Data {
        let header = "Content-Length: \(payload.count)\r\n\r\n"
        var data = Data(header.utf8)
        data.append(payload)
        return data
    }

    public func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var messages: [Data] = []
        while let message = popMessage() {
            messages.append(message)
        }
        return messages
    }

    private func popMessage() -> Data? {
        let sep = Data("\r\n\r\n".utf8)
        guard let sepRange = buffer.range(of: sep) else { return nil }
        let headerData = buffer.subdata(in: 0..<sepRange.lowerBound)
        guard let header = String(data: headerData, encoding: .utf8) else {
            buffer.removeAll()
            return nil
        }
        var length: Int?
        for line in header.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                length = Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        guard let length else { return nil }
        let bodyStart = sepRange.upperBound
        let bodyEnd = bodyStart + length
        guard buffer.count >= bodyEnd else { return nil }
        let body = buffer.subdata(in: bodyStart..<bodyEnd)
        buffer.removeSubrange(0..<bodyEnd)
        return body
    }
}

public protocol ByteTransport: AnyObject {
    func write(_ data: Data) throws
    func readSome() throws -> Data?
    func close()
}

/// In-memory duplex used by tests. Pair two ends with `makePair()`.
public final class MemoryTransport: ByteTransport, @unchecked Sendable {
    private let condition = NSCondition()
    private var chunks: [Data] = []
    private var closed = false
    /// Strong until `close()` so a pair cannot drop a peer mid-read.
    fileprivate var peer: MemoryTransport?

    public init() {}

    public static func makePair() -> (MemoryTransport, MemoryTransport) {
        let a = MemoryTransport()
        let b = MemoryTransport()
        a.peer = b
        b.peer = a
        return (a, b)
    }

    public func write(_ data: Data) throws {
        guard let peer else { throw JSONRPCError.closed }
        peer.condition.lock()
        defer { peer.condition.unlock() }
        if peer.closed { throw JSONRPCError.closed }
        peer.chunks.append(data)
        peer.condition.signal()
    }

    public func readSome() throws -> Data? {
        condition.lock()
        defer { condition.unlock() }
        while chunks.isEmpty && !closed {
            condition.wait()
        }
        if chunks.isEmpty { return nil }
        return chunks.removeFirst()
    }

    public func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
        if let peer {
            peer.condition.lock()
            peer.closed = true
            peer.condition.broadcast()
            peer.condition.unlock()
            peer.peer = nil
        }
        peer = nil
    }
}

public final class JSONRPCSession: @unchecked Sendable {
    private let transport: ByteTransport
    private let framer = JSONRPCFramer()
    private let lock = NSLock()
    private var nextID = 1
    private var pending: [Int: (Result<JSONValue, Error>) -> Void] = [:]
    public var onNotification: ((String, JSONValue?) -> Void)?
    public var onServerRequest: ((Int, String, JSONValue?) -> JSONValue?)?

    public init(transport: ByteTransport) {
        self.transport = transport
    }

    public func startReading() {
        // A dedicated thread, not GCD: the read loop blocks on the transport,
        // and Linux libdispatch can stall other work if those waits occupy the
        // cooperative pool while a test thread is also blocked on a semaphore.
        let thread = Thread { [weak self] in
            self?.readLoop()
        }
        thread.name = "quill.jsonrpc"
        thread.start()
    }

    public func notify(method: String, params: JSONValue? = nil) throws {
        var obj: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
        ]
        if let params { obj["params"] = params }
        try transport.write(framer.encode(try JSONValue.encode(.object(obj))))
    }

    public func request(method: String, params: JSONValue? = nil, timeout: TimeInterval = 5) throws -> JSONValue {
        let id: Int = locked {
            let id = nextID
            nextID += 1
            return id
        }
        var obj: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
        ]
        if let params { obj["params"] = params }
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<JSONValue, Error>?
        locked {
            pending[id] = { r in
                result = r
                semaphore.signal()
            }
        }
        try transport.write(framer.encode(try JSONValue.encode(.object(obj))))
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            locked { pending.removeValue(forKey: id) }
            throw JSONRPCError.timeout
        }
        switch result {
        case .success(let value): return value
        case .failure(let error): throw error
        case .none: throw JSONRPCError.closed
        }
    }

    public func reply(id: Int, result: JSONValue) throws {
        let obj: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "result": result,
        ]
        try transport.write(framer.encode(try JSONValue.encode(.object(obj))))
    }

    public func close() {
        transport.close()
    }

    private func readLoop() {
        while true {
            do {
                guard let chunk = try transport.readSome() else { return }
                let payloads = framer.append(chunk)
                for payload in payloads {
                    handle(payload)
                }
            } catch {
                return
            }
        }
    }

    private func handle(_ payload: Data) {
        guard let value = try? JSONValue.decode(payload), let obj = value.object else { return }
        if let idVal = obj["id"], obj["method"] == nil {
            let id = idVal.int ?? Int(idVal.string ?? "") ?? -1
            let callback = locked { pending.removeValue(forKey: id) }
            if let err = obj["error"]?.object {
                let code = err["code"]?.int ?? -1
                let message = err["message"]?.string ?? "error"
                callback?(.failure(JSONRPCError.response(code: code, message: message)))
            } else {
                callback?(.success(obj["result"] ?? .null))
            }
            return
        }
        if let method = obj["method"]?.string {
            let params = obj["params"]
            if let idVal = obj["id"] {
                let id = idVal.int ?? Int(idVal.string ?? "") ?? 0
                let result = onServerRequest?(id, method, params) ?? .null
                try? reply(id: id, result: result)
            } else {
                onNotification?(method, params)
            }
        }
    }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
