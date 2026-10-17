import Foundation

/// What a configured shell command asked Quill to do with its output.
public enum HookResult: Equatable, Sendable {
    /// Open `path`. `line` and `column` are 1-based when the last stdout line was `path:line` or `path:line:col`.
    case open(path: String, line: Int?, column: Int?)
    /// Show `text` on the status line. Empty clears a previous error.
    case status(String)
}

/// Interprets a shell command's output. The command itself is config, not built-in knowledge.
public enum ShellHook {
    public static func interpret(stdout: String, stderr: String, status: Int32) -> HookResult {
        if status != 0 {
            if let line = lastNonEmptyLine(stderr) { return .status(line) }
            if let line = lastNonEmptyLine(stdout) { return .status(line) }
            return .status("command failed (\(status))")
        }
        guard let line = lastNonEmptyLine(stdout) else { return .status("") }
        let split = LaunchRequest.splitLocation(line)
        return .open(path: split.path, line: split.line, column: split.column)
    }

    private static func lastNonEmptyLine(_ text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        var index = lines.count
        while index > 0 {
            index -= 1
            if !lines[index].isEmpty { return String(lines[index]) }
        }
        return nil
    }
}
