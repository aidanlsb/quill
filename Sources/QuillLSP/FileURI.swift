import Foundation

/// Local `file://` paths from an untrusted language server.
public enum FileURI {
    /// Absolute local path, with `.` and `..` removed. Other schemes and remote hosts are `nil`.
    public static func localPath(from uri: String) -> String? {
        guard let components = URLComponents(string: uri),
              components.scheme?.lowercased() == "file" else { return nil }
        if let host = components.host?.lowercased(), !host.isEmpty, host != "localhost" {
            return nil
        }
        let raw = components.percentEncodedPath.removingPercentEncoding ?? components.path
        guard raw.hasPrefix("/"), raw != "/" else { return nil }
        let path = URL(fileURLWithPath: raw).standardizedFileURL.path
        guard path.hasPrefix("/"), path != "/" else { return nil }
        return path
    }

    /// True when `path` resolves inside `root`, including through symlinks.
    public static func isInside(_ path: String, root: URL) -> Bool {
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        if file == rootPath { return true }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return file.hasPrefix(prefix)
    }
}

/// Where a definition or reference may be opened. Outside the workspace, or not a local file, is `nil`.
public enum LSPNavigation {
    public static func file(toOpen uri: String, workspace: URL) -> URL? {
        guard let path = FileURI.localPath(from: uri), FileURI.isInside(path, root: workspace) else { return nil }
        return URL(fileURLWithPath: path)
    }
}

/// Environment handed to a language server. The parent process may hold tokens the server does not need.
public enum ProcessEnvironment {
    public static let inheritedKeys = [
        "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR",
        "LANG", "LC_ALL", "LC_CTYPE", "LC_MESSAGES",
        "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR",
        "TERM",
    ]

    /// Allowlisted parent variables, then `overrides` from config (which may add a value on purpose).
    public static func forChild(parent: [String: String], overrides: [String: String]) -> [String: String] {
        var child: [String: String] = [:]
        for key in inheritedKeys {
            if let value = parent[key] { child[key] = value }
        }
        for (key, value) in overrides {
            child[key] = value
        }
        return child
    }
}
