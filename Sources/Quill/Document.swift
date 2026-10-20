import Foundation
import Observation
import QuillFS
import QuillVim
import QuillWorkspace

/// The open buffer: its kind, the bytes last read from disk, and a generation
/// that every async result checks before it touches the buffer.
@MainActor
@Observable
final class Document {
    enum Kind: Equatable {
        case untitled
        case file(url: URL, ending: LineEnding, loadedAt: Date?)
        case directory(url: URL, snapshot: DirectorySnapshot)
    }

    enum SaveOutcome: Equatable {
        /// `text` is the snapshot that was written, not keystrokes that landed later.
        case saved(text: String)
        case conflict
        case superseded
        case noFile
    }

    enum Failure: LocalizedError, Equatable {
        case message(String)
        case noFile

        var errorDescription: String? {
            switch self {
            case .message(let text): return text
            case .noFile: return "No file"
            }
        }
    }

    let engine: Engine
    private(set) var kind: Kind = .untitled
    private(set) var generation = 0
    private(set) var modified = false
    /// Bumps when the buffer text changes so a second window can catch up.
    private(set) var renderToken = 0
    private(set) var rootURL: URL
    private var notedStamp = -1
    @ObservationIgnored var onReplaced: (@MainActor () -> Void)?
    @ObservationIgnored var diskWrite: @Sendable (Data, URL) async throws -> Void = { bytes, url in
        try await Task.detached {
            try bytes.write(to: url, options: .atomic)
        }.value
    }
    @ObservationIgnored var readFile: @Sendable (URL) async throws -> Data = { url in
        try await Task.detached {
            try Data(contentsOf: url)
        }.value
    }

    private var openTicket = 0
    private var confirmOverwrite = false
    private var pendingJumps: [String: LaunchTarget] = [:]

    init(engine: Engine, root: URL) {
        self.engine = engine
        self.rootURL = root
    }

    var title: String {
        switch kind {
        case .untitled: "Untitled"
        case .file(let url, _, _): url.lastPathComponent
        case .directory(let url, _): url.lastPathComponent + "/"
        }
    }

    var url: URL? {
        switch kind {
        case .untitled: nil
        case .file(let url, _, _), .directory(let url, _): url
        }
    }

    var isDirectory: Bool {
        if case .directory = kind { return true }
        return false
    }

    var snapshot: DirectorySnapshot? {
        if case .directory(_, let snapshot) = kind { return snapshot }
        return nil
    }

    /// Views read this. It changes on install and on a text edit, not on a motion.
    var refreshID: Int { generation &+ renderToken }

    func noteEdit() {
        if modified != engine.isModified { modified = engine.isModified }
        if notedStamp != engine.changeStamp {
            notedStamp = engine.changeStamp
            renderToken += 1
        }
    }

    func markClean() {
        engine.markSaved()
        modified = false
    }

    func noteJump(_ target: LaunchTarget, forPath path: String) {
        if target.line != nil {
            pendingJumps[path] = target
        } else {
            pendingJumps.removeValue(forKey: path)
        }
    }

    func takeJump(for url: URL) -> LaunchTarget? {
        pendingJumps.removeValue(forKey: url.standardizedFileURL.path)
    }

    func cancelJump(for url: URL) {
        pendingJumps.removeValue(forKey: url.standardizedFileURL.path)
    }

    func resolve(_ text: String) -> URL {
        if text.hasPrefix("/") { return URL(fileURLWithPath: text) }
        return rootURL.appendingPathComponent(text)
    }

    /// Directories and missing files install before this returns.
    /// An existing file returns `false`; the caller reads it.
    func openSynchronously(_ url: URL) throws -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if exists, isDir.boolValue {
            if let error = loadDirectory(url) { throw Failure.message(error) }
            return true
        }
        if !exists {
            _ = bumpTicket()
            installFile(try TextCodec.decode(Data()), url: url)
            return true
        }
        return false
    }

    /// `false` when a newer open or reload won the race.
    func open(_ url: URL) async throws -> Bool {
        if try openSynchronously(url) { return true }
        let ticket = bumpTicket()
        let data: Data
        let readBegan = StartupProbe.begin("fileReadMs")
        do {
            data = try await readFile(url)
        } catch {
            StartupProbe.end("fileReadMs", readBegan)
            guard ticket == openTicket else { return false }
            throw error
        }
        StartupProbe.end("fileReadMs", readBegan)
        guard ticket == openTicket else { return false }
        let decodeBegan = StartupProbe.begin("fileDecodeMs")
        let decoded = try TextCodec.decode(data)
        StartupProbe.end("fileDecodeMs", decodeBegan)
        let installBegan = StartupProbe.begin("fileInstallMs")
        installFile(decoded, url: url)
        StartupProbe.end("fileInstallMs", installBegan)
        return true
    }

    func newUntitled() {
        _ = bumpTicket()
        engine.load(text: "")
        kind = .untitled
        installed()
    }

    /// `:e` with no path. `false` when a newer open replaced this buffer first.
    func reload() async throws -> Bool {
        guard let url else { throw Failure.noFile }
        if isDirectory {
            if let error = loadDirectory(url) { throw Failure.message(error) }
            return true
        }
        let ticket = bumpTicket()
        let data: Data
        do {
            data = try await readFile(url)
        } catch {
            guard ticket == openTicket else { return false }
            throw error
        }
        guard ticket == openTicket else { return false }
        installFile(try TextCodec.decode(data), url: url)
        return true
    }

    func claimUntitled(_ url: URL) {
        kind = .file(url: url, ending: .lf, loadedAt: nil)
        rootURL = url.deletingLastPathComponent()
    }

    /// Snapshot taken before `save()` returns, so keystrokes after `:w` stay out of the write.
    struct PendingSave: Sendable {
        let stamp: Int
        let generation: Int
        let url: URL
        let text: String
        let data: Data
        let write: @Sendable (Data, URL) async throws -> Void
    }

    enum PreparedSave {
        case ready(PendingSave)
        case conflict
        case noFile
    }

    func prepareSave(force: Bool = false) -> PreparedSave {
        guard case .file(let url, let ending, let loadedAt) = kind else { return .noFile }
        if let loadedAt, let current = modificationDate(url),
           ExternalChange.conflicts(loaded: loadedAt, current: current),
           !force, !confirmOverwrite {
            confirmOverwrite = true
            return .conflict
        }
        return .ready(PendingSave(
            stamp: engine.changeStamp,
            generation: generation,
            url: url,
            text: engine.text,
            data: TextCodec.encode(engine.text, ending: ending),
            write: diskWrite
        ))
    }

    func finishSave(_ request: PendingSave) async throws -> SaveOutcome {
        try await request.write(request.data, request.url)
        guard generation == request.generation, url == request.url else { return .superseded }
        engine.markSaved(stamp: request.stamp)
        modified = engine.isModified
        if case .file(_, let ending, _) = kind {
            kind = .file(url: request.url, ending: ending, loadedAt: modificationDate(request.url))
        }
        confirmOverwrite = false
        return .saved(text: request.text)
    }

    @discardableResult
    func loadDirectory(_ url: URL) -> String? {
        _ = bumpTicket()
        do {
            let snap = try DirectoryListing.snapshot(of: url)
            installDirectory(snap, url: url)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func listingLines() -> [ListingLine] {
        var lines: [ListingLine] = []
        for (line, anchor) in engine.buffer.directoryEntryLines() {
            let parsed = ParsedDirLine(line)
            if parsed.name.isEmpty { continue }
            if let anchor, case .directoryEntry(let path, _, let transfer) = anchor.kind {
                let kind: LineTransfer
                switch transfer {
                case .identity: kind = .identity
                case .move: kind = .move
                case .copy: kind = .copy
                }
                lines.append(ListingLine(
                    name: parsed.name,
                    isDirectory: parsed.isDirectory,
                    entryID: anchor.id.raw,
                    sourcePath: path,
                    transfer: kind
                ))
            } else {
                lines.append(ListingLine(name: parsed.name, isDirectory: parsed.isDirectory))
            }
        }
        return lines
    }

    func planDirectorySave() -> [FSOperation] {
        guard let snapshot else { return [] }
        return DirectoryListing.plan(original: snapshot, lines: listingLines())
    }

    func applyDirectoryOps(_ ops: [FSOperation]) throws -> String? {
        try FSExecutor.apply(ops, fs: TrashFileSystem())
        if case .directory(let url, _) = kind, let error = loadDirectory(url) {
            return error
        }
        engine.markSaved()
        modified = false
        return nil
    }

    private func bumpTicket() -> Int {
        openTicket &+= 1
        return openTicket
    }

    private func installFile(_ decoded: TextCodec.Decoded, url: URL) {
        engine.load(text: decoded.text)
        kind = .file(url: url, ending: decoded.ending, loadedAt: modificationDate(url))
        rootURL = url.deletingLastPathComponent()
        confirmOverwrite = false
        installed()
    }

    private func installDirectory(_ snap: DirectorySnapshot, url: URL) {
        engine.load(text: DirectoryListing.render(snap))
        for (index, entry) in snap.entries.enumerated() {
            engine.setDirectoryAnchor(
                line: index,
                id: entry.entryID ?? DirectoryListing.stableID(for: entry.originalURL?.path ?? entry.name),
                sourcePath: entry.originalURL?.path ?? url.appendingPathComponent(entry.name).path,
                isDirectory: entry.isDirectory
            )
        }
        kind = .directory(url: url, snapshot: snap)
        rootURL = url
        installed()
    }

    private func installed() {
        generation += 1
        modified = false
        notedStamp = engine.changeStamp
        renderToken += 1
        onReplaced?()
        StartupUI.noteContent()
    }

    private func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

struct TrashFileSystem: FileSystem {
    private let fm = FileManager.default

    func exists(_ path: String) -> Bool { fm.fileExists(atPath: path) }

    func createDirectory(_ path: String) throws {
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    func writeFile(_ path: String, data: Data) throws {
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    func remove(_ path: String) throws {
        var trashed: NSURL?
        try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &trashed)
    }

    func move(from: String, to: String) throws {
        try fm.moveItem(atPath: from, toPath: to)
    }

    func copy(from: String, to: String) throws {
        try fm.copyItem(atPath: from, toPath: to)
    }
}
