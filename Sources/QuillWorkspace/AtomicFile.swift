import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Replace a file by writing a temporary sibling and renaming it into place.
///
/// The destination is inspected with `lstat`. A symlink is refused, so a save
/// cannot follow a link onto another file. `rename` replaces a name that
/// becomes a symlink during the write, and that replacement does not follow
/// the link either. A new file is mode `0644`. An existing regular file keeps
/// its permission bits.
public enum AtomicFile {
    public struct Failure: Error, Equatable, LocalizedError, Sendable {
        public var message: String

        public var errorDescription: String? { message }
    }

    public static func write(_ data: Data, to url: URL) throws {
        let path = url.path
        let mode = try destinationMode(path)
        let directory = (path as NSString).deletingLastPathComponent
        guard !directory.isEmpty, directory != path else {
            throw Failure(message: "Not a regular file")
        }
        let (fd, temp) = try makeTemporary(in: directory, destination: path)
        do {
            try writeAll(fd, data, destination: path)
            if fchmod(fd, mode) != 0 {
                throw errnoFailure(path)
            }
        } catch {
            close(fd)
            unlink(temp)
            throw error
        }
        if close(fd) != 0 {
            let failure = errnoFailure(path)
            unlink(temp)
            throw failure
        }
        if rename(temp, path) != 0 {
            let failure = errnoFailure(path)
            unlink(temp)
            throw failure
        }
    }

    private static func destinationMode(_ path: String) throws -> mode_t {
        var info = stat()
        if lstat(path, &info) != 0 {
            if errno == ENOENT { return 0o644 }
            throw errnoFailure(path)
        }
        let kind = mode_t(info.st_mode) & S_IFMT
        if kind == S_IFLNK {
            throw Failure(message: "Refusing to write through a symlink")
        }
        if kind != S_IFREG {
            throw Failure(message: "Not a regular file")
        }
        return mode_t(info.st_mode) & 0o777
    }

    private static func makeTemporary(in directory: String, destination: String) throws -> (Int32, String) {
        var bytes = Array((directory + "/.quill-save-XXXXXX").utf8CString)
        let fd = bytes.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return mkstemp(base)
        }
        guard fd >= 0 else { throw errnoFailure(destination) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
        let temp = String(decoding: bytes[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return (fd, temp)
    }

    private static func writeAll(_ fd: Int32, _ data: Data, destination: String) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            var offset = 0
            while offset < raw.count {
                let wrote = posixWrite(fd, base.advanced(by: offset), raw.count - offset)
                if wrote < 0 {
                    if errno == EINTR { continue }
                    throw errnoFailure(destination)
                }
                if wrote == 0 { throw errnoFailure(destination) }
                offset += wrote
            }
        }
    }

    private static func posixWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        Darwin.write(fd, buffer, count)
        #else
        Glibc.write(fd, buffer, count)
        #endif
    }

    private static func errnoFailure(_ path: String) -> Failure {
        Failure(message: "Could not write \(path) (errno \(errno))")
    }
}
