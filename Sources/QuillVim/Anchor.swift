/// Stable identity that moves with edits. Directory lines, marks, and
/// diagnostics all hang off the same adjustment rules.
public struct AnchorID: Hashable, Sendable {
    public var raw: UInt64

    public init(raw: UInt64) {
        self.raw = raw
    }
}

public enum AnchorGravity: Equatable, Sendable {
    /// Stay put when text is inserted at the anchor (line-start identity).
    case left
    /// Move across text inserted at the anchor.
    case right
}

/// How a directory-entry anchor should be applied when the listing is saved.
public enum DirectoryTransfer: Equatable, Sendable {
    /// The line still is the original entry.
    case identity
    /// `dd` + `p`: the file moves.
    case move
    /// `yy` + `p`: the file is copied.
    case copy
}

public enum AnchorKind: Equatable, Sendable {
    case mark(String)
    case directoryEntry(sourcePath: String, isDirectory: Bool, transfer: DirectoryTransfer)
}

public struct Anchor: Equatable, Sendable {
    public var id: AnchorID
    public var offset: Int
    public var gravity: AnchorGravity
    public var kind: AnchorKind

    public init(id: AnchorID, offset: Int, gravity: AnchorGravity, kind: AnchorKind) {
        self.id = id
        self.offset = offset
        self.gravity = gravity
        self.kind = kind
    }
}
