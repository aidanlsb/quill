import Foundation

public enum JSONRPCError: Error, Equatable {
    case parse(String)
    case timeout
    case closed
    case serverUnavailable(String)
    case response(code: Int, message: String)
}

/// LSP / JSON-RPC 2.0 header framing (`Content-Length: N\r\n\r\n{json}`).
// quill-concurrency: The decode buffer is only used on the session read thread.
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
// quill-concurrency: NSCondition guards the chunk queue shared by the pair.
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

public enum JSONRPCID: Hashable, Sendable {
    case number(Int)
    case string(String)

    public var json: JSONValue {
        switch self {
        case .number(let n): return .number(Double(n))
        case .string(let s): return .string(s)
        }
    }

    public static func parse(_ value: JSONValue) -> JSONRPCID? {
        if let n = value.int { return .number(n) }
        if let s = value.string { return .string(s) }
        return nil
    }
}

// quill-concurrency: NSLock guards pending requests; writeLock guards the transport write.
public final class JSONRPCSession: @unchecked Sendable {
    private let transport: ByteTransport
    private let framer = JSONRPCFramer()
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var nextID = 1
    private var pending: [JSONRPCID: (Result<JSONValue, Error>) -> Void] = [:]
    public var onNotification: ((String, JSONValue?) -> Void)?
    /// Return nil to answer with JSON-RPC MethodNotFound. Return `.null` for an explicit null result.
    public var onServerRequest: ((JSONRPCID, String, JSONValue?) -> JSONValue?)?

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
        try send(obj)
    }

    public func request(method: String, params: JSONValue? = nil, timeout: TimeInterval = 5) throws -> JSONValue {
        let id = allocateID()
        let box = ResponseBox()
        locked {
            pending[id] = { result in
                box.condition.lock()
                box.result = result
                box.condition.signal()
                box.condition.unlock()
            }
        }
        do {
            try send(requestObject(id: id, method: method, params: params))
        } catch {
            locked { pending.removeValue(forKey: id) }
            throw error
        }
        box.condition.lock()
        let deadline = Date().addingTimeInterval(timeout)
        while box.result == nil {
            if !box.condition.wait(until: deadline) { break }
        }
        let result = box.result
        box.condition.unlock()
        if result == nil {
            locked { pending.removeValue(forKey: id) }
            throw JSONRPCError.timeout
        }
        switch result {
        case .success(let value): return value
        case .failure(let error): throw error
        case nil: throw JSONRPCError.closed
        }
    }

    public func request(method: String, params: JSONValue? = nil) async throws -> JSONValue {
        let id = allocateID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                let gate = OnceResume()
                locked {
                    pending[id] = { result in
                        gate.resume(continuation, with: result)
                    }
                }
                do {
                    try send(requestObject(id: id, method: method, params: params))
                } catch {
                    locked { pending.removeValue(forKey: id) }
                    gate.resume(continuation, with: .failure(error))
                }
            }
        } onCancel: { [weak self] in
            try? self?.notify(method: "$/cancelRequest", params: .object(["id": id.json]))
        }
    }

    public func reply(id: JSONRPCID, result: JSONValue) throws {
        try send([
            "jsonrpc": .string("2.0"),
            "id": id.json,
            "result": result,
        ])
    }

    public func replyError(id: JSONRPCID, code: Int, message: String) throws {
        try send([
            "jsonrpc": .string("2.0"),
            "id": id.json,
            "error": .object([
                "code": .number(Double(code)),
                "message": .string(message),
            ]),
        ])
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
        if let idVal = obj["id"], obj["method"] == nil, let id = JSONRPCID.parse(idVal) {
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
            if let idVal = obj["id"], let id = JSONRPCID.parse(idVal) {
                if let result = onServerRequest?(id, method, params) {
                    try? reply(id: id, result: result)
                } else {
                    try? replyError(id: id, code: -32601, message: "Method not found: \(method)")
                }
            } else {
                onNotification?(method, params)
            }
        }
    }

    private func allocateID() -> JSONRPCID {
        locked {
            let id = nextID
            nextID += 1
            return .number(id)
        }
    }

    private func requestObject(id: JSONRPCID, method: String, params: JSONValue?) -> [String: JSONValue] {
        var obj: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": id.json,
            "method": .string(method),
        ]
        if let params { obj["params"] = params }
        return obj
    }

    private func send(_ object: [String: JSONValue]) throws {
        let framed = framer.encode(try JSONValue.encode(.object(object)))
        writeLock.lock()
        defer { writeLock.unlock() }
        try transport.write(framed)
    }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

// quill-concurrency: NSCondition guards the single waiter and the stored result.
private final class ResponseBox: @unchecked Sendable {
    let condition = NSCondition()
    var result: Result<JSONValue, Error>?
}

// quill-concurrency: NSLock makes resume happen once across threads.
private final class OnceResume: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func resume(_ continuation: CheckedContinuation<JSONValue, Error>, with result: Result<JSONValue, Error>) {
        lock.lock()
        if done {
            lock.unlock()
            return
        }
        done = true
        lock.unlock()
        continuation.resume(with: result)
    }
}
