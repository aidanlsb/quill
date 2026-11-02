import Foundation

/// Directory used for the file picker, live grep, `-`, and relative paths when
/// there is no open file. Finder and Dock launches have cwd `/`; that is never
/// a project root.
public enum BrowseRoot {
    /// Path-only. Empty paths and `/` are never a project root. Does not stat.
    public static func isFilesystemRoot(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.isEmpty || path == "/"
    }

    /// Remembered folder without stating it. `/` is dropped; missing directories
    /// stay until `resolve` runs (picker, `-`, `:e`), not launch or a keystroke.
    public static func stored(_ url: URL?) -> URL? {
        guard let url else { return nil }
        let standardized = url.standardizedFileURL
        if isFilesystemRoot(standardized) { return nil }
        return standardized
    }

    /// A real directory that is not the filesystem root.
    public static func isUsable(_ url: URL) -> Bool {
        if isFilesystemRoot(url) { return false }
        let path = url.standardizedFileURL.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return false }
        return isDir.boolValue
    }

    public static func directory(containing url: URL, isDirectory: Bool) -> URL {
        let standardized = url.standardizedFileURL
        return isDirectory ? standardized : standardized.deletingLastPathComponent()
    }

    /// Open file's folder, else last-used, else home. Never `/`.
    public static func resolve(
        openFile: URL?,
        isDirectory: Bool,
        lastUsed: URL?,
        home: URL
    ) -> URL {
        if let openFile {
            let dir = directory(containing: openFile, isDirectory: isDirectory)
            if isUsable(dir) { return dir }
        }
        if let lastUsed, isUsable(lastUsed) { return lastUsed.standardizedFileURL }
        if isUsable(home) { return home.standardizedFileURL }
        let fallback = home.standardizedFileURL
        if fallback.path != "/" { return fallback }
        return FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    }

    /// Resolve a typed or launch path against `base`. Relative paths never use cwd.
    public static func absolute(_ path: String, relativeTo base: URL) -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("~") {
            let home = FileManager.default.homeDirectoryForCurrentUser
            if trimmed == "~" || trimmed == "~/" { return home.standardizedFileURL }
            if trimmed.hasPrefix("~/") {
                return home.appendingPathComponent(String(trimmed.dropFirst(2))).standardizedFileURL
            }
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL
        }
        return base.appendingPathComponent(trimmed).standardizedFileURL
    }
}
