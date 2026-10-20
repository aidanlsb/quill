import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One running Quill. The CLI connects here instead of starting a second process.
/// The socket lives in the user's runtime directory (`QUILL_SOCKET` overrides it).
public enum InstanceSocket {
    /// `sockaddr_un.sun_path` holds 104 bytes on Darwin, including the NUL.
    public static let maxPathLength = 103

    public static func path(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment["QUILL_SOCKET"], !override.isEmpty {
            return override
        }
        #if os(macOS)
        return darwinUserTemp() + "quill.sock"
        #else
        let runtime = environment["XDG_RUNTIME_DIR"] ?? "/tmp"
        let trimmed = runtime.hasSuffix("/") ? String(runtime.dropLast()) : runtime
        return trimmed + "/quill-" + String(getuid()) + "/quill.sock"
        #endif
    }

    #if os(macOS)
    private static func darwinUserTemp() -> String {
        let needed = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard needed > 1 else { return "/tmp/" }
        var buffer = [CChar](repeating: 0, count: needed)
        let wrote = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, needed)
        guard wrote > 1 else { return "/tmp/" }
        let bytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        let text = String(decoding: bytes, as: UTF8.self)
        return text.hasSuffix("/") ? text : text + "/"
    }
    #endif
}

public enum HandoffResult: Equatable, Sendable {
    case delivered
    case notRunning
    case failed
}

public enum InstanceClaim {
    /// This process owns the socket and should keep running.
    case primary(InstanceServer)
    /// Another process accepted `targets`.
    case delivered
    /// No listener, and this process could not take the socket.
    case unavailable
}

enum HandoffCodec {
    static func line(for targets: [LaunchTarget]) -> String? {
        let message = HandoffMessage(v: 1, targets: targets)
        guard let data = try? JSONEncoder().encode(message) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func targets(from line: String) -> [LaunchTarget]? {
        guard let data = line.data(using: .utf8),
              let message = try? JSONDecoder().decode(HandoffMessage.self, from: data),
              message.v == 1
        else { return nil }
        return message.targets
    }
}

private struct HandoffMessage: Codable {
    var v: Int
    var targets: [LaunchTarget]
}

public enum InstanceClient {
    public static func send(_ targets: [LaunchTarget], socket path: String) -> HandoffResult {
        guard let line = HandoffCodec.line(for: targets) else { return .failed }
        switch exchange(line + "\n", socket: path) {
        case "ok"?:
            return .delivered
        case nil:
            return .notRunning
        default:
            return .failed
        }
    }

    /// Writes one line and returns the reply without its trailing newline.
    /// `nil` means nothing is listening.
    static func exchange(_ line: String, socket path: String) -> String? {
        guard path.utf8.count <= InstanceSocket.maxPathLength else { return nil }
        let fd = streamSocket()
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        #if os(macOS)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        let connected = withUnixAddress(path) { pointer, length in
            connect(fd, pointer, length)
        }
        guard connected == 0 else { return nil }
        guard writeAll(fd, line) else { return nil }
        return readLine(fd)
    }
}

public enum InstanceBridge {
    /// Bind the socket, or deliver `targets` to the instance that already has it.
    /// A stale socket file (listener gone) is removed once and the bind is retried.
    public static func claim(
        socket path: String,
        targets: [LaunchTarget],
        onMessage: @escaping @Sendable ([LaunchTarget]) -> Void
    ) -> InstanceClaim {
        if let server = InstanceServer.start(path: path, onMessage: onMessage) {
            return .primary(server)
        }
        switch InstanceClient.send(targets, socket: path) {
        case .delivered:
            return .delivered
        case .failed:
            return .unavailable
        case .notRunning:
            unlink(path)
            if let server = InstanceServer.start(path: path, onMessage: onMessage) {
                return .primary(server)
            }
            if InstanceClient.send(targets, socket: path) == .delivered {
                return .delivered
            }
            return .unavailable
        }
    }
}

/// Accepts one handoff at a time. `stop` closes the listener and unlinks the socket.
// quill-concurrency: NSLock and NSCondition guard the listen fd and the accept thread's exit.
public final class InstanceServer: @unchecked Sendable {
    private let lock = NSLock()
    private let done = NSCondition()
    private var listenFD: Int32 = -1
    private var wakeRead: Int32 = -1
    private var wakeWrite: Int32 = -1
    private var socketPath = ""
    private var threadExited = false
    private let onMessage: @Sendable ([LaunchTarget]) -> Void

    public static func start(path: String, onMessage: @escaping @Sendable ([LaunchTarget]) -> Void) -> InstanceServer? {
        guard path.utf8.count <= InstanceSocket.maxPathLength else { return nil }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        if !FileManager.default.fileExists(atPath: parent) {
            do {
                try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            } catch {
                return nil
            }
            chmod(parent, 0o700)
        }
        let fd = streamSocket()
        guard fd >= 0 else { return nil }
        let flags = fcntl(fd, F_GETFD)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
        }
        let bound = withUnixAddress(path) { pointer, length in
            bind(fd, pointer, length)
        }
        guard bound == 0 else {
            close(fd)
            return nil
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            close(fd)
            unlink(path)
            return nil
        }
        guard let wake = wakePipe() else {
            close(fd)
            unlink(path)
            return nil
        }
        let server = InstanceServer(fd: fd, path: path, wake: wake, onMessage: onMessage)
        Thread.detachNewThread { [weak server] in
            server?.loop()
        }
        return server
    }

    private init(fd: Int32, path: String, wake: (Int32, Int32), onMessage: @escaping @Sendable ([LaunchTarget]) -> Void) {
        self.listenFD = fd
        self.socketPath = path
        self.wakeRead = wake.0
        self.wakeWrite = wake.1
        self.onMessage = onMessage
    }

    public func stop(unlinkSocket: Bool = true) {
        lock.lock()
        let fd = listenFD
        let wake = wakeWrite
        wakeWrite = -1
        let path = socketPath
        lock.unlock()
        if wake >= 0 {
            var byte: UInt8 = 1
            _ = write(wake, &byte, 1)
            close(wake)
        }
        done.lock()
        let deadline = Date().addingTimeInterval(2)
        while !threadExited && Date() < deadline {
            _ = done.wait(until: deadline)
        }
        done.unlock()
        if fd >= 0 { close(fd) }
        lock.lock()
        let readEnd = wakeRead
        wakeRead = -1
        listenFD = -1
        lock.unlock()
        if readEnd >= 0 { close(readEnd) }
        if unlinkSocket && !path.isEmpty { unlink(path) }
    }

    private func loop() {
        defer {
            done.lock()
            threadExited = true
            done.broadcast()
            done.unlock()
        }
        while true {
            lock.lock()
            let fd = listenFD
            let wake = wakeRead
            lock.unlock()
            if fd < 0 || wake < 0 { return }
            var fds = [
                pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wake, events: Int16(POLLIN), revents: 0),
            ]
            let ready = poll(&fds, nfds_t(fds.count), -1)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if fds[1].revents != 0 { return }
            if fds[0].revents & Int16(POLLIN) == 0 { return }
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            let flags = fcntl(client, F_GETFD)
            if flags >= 0 {
                _ = fcntl(client, F_SETFD, flags | FD_CLOEXEC)
            }
            handle(client)
            close(client)
        }
    }

    private func handle(_ client: Int32) {
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        #if os(macOS)
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        guard peerIsCurrentUser(client), let line = readLine(client), let targets = HandoffCodec.targets(from: line) else {
            _ = writeAll(client, "no\n")
            return
        }
        onMessage(targets)
        _ = writeAll(client, "ok\n")
    }
}

private func wakePipe() -> (Int32, Int32)? {
    var fds = [Int32](repeating: -1, count: 2)
    guard pipe(&fds) == 0 else { return nil }
    for fd in fds {
        let flags = fcntl(fd, F_GETFD)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
        }
    }
    return (fds[0], fds[1])
}

private func streamSocket() -> Int32 {
    #if os(Linux)
    socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    #else
    socket(AF_UNIX, SOCK_STREAM, 0)
    #endif
}

private func peerIsCurrentUser(_ fd: Int32) -> Bool {
    #if os(macOS)
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard getpeereid(fd, &uid, &gid) == 0 else { return false }
    return uid == getuid()
    #else
    var cred = PeerCred()
    var length = socklen_t(MemoryLayout<PeerCred>.size)
    guard getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &length) == 0 else { return false }
    return cred.uid == getuid()
    #endif
}

#if !os(macOS)
private struct PeerCred {
    var pid: Int32 = 0
    var uid: UInt32 = 0
    var gid: UInt32 = 0
}
#endif

@discardableResult
private func withUnixAddress(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    #if os(macOS)
    // Darwin rejects an address whose sun_len is still zero.
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    #endif
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    let bytes = Array(path.utf8CString)
    guard bytes.count <= capacity else { return -1 }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        for (index, byte) in bytes.enumerated() {
            raw[index] = UInt8(bitPattern: byte)
        }
    }
    return withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
            body(sock, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

private func readLine(_ fd: Int32) -> String? {
    var data = Data()
    var byte: UInt8 = 0
    while data.count < 1_000_000 {
        let count = read(fd, &byte, 1)
        if count == 0 { return nil }
        if count < 0 {
            if errno == EINTR { continue }
            return nil
        }
        if byte == 10 {
            return String(data: data, encoding: .utf8)
        }
        data.append(byte)
    }
    return nil
}

private func writeAll(_ fd: Int32, _ text: String) -> Bool {
    let bytes = Array(text.utf8)
    var sent = 0
    while sent < bytes.count {
        let count = bytes.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            return send(fd, base.advanced(by: sent), bytes.count - sent, noSignal)
        }
        if count < 0 {
            if errno == EINTR { continue }
            return false
        }
        if count == 0 { return false }
        sent += count
    }
    return true
}

private var noSignal: Int32 {
    #if os(Linux)
    Int32(MSG_NOSIGNAL)
    #else
    // SO_NOSIGPIPE is set on the socket. A zero flags word avoids the Darwin MSG_NOSIGNAL value.
    0
    #endif
}
