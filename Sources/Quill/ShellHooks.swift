import Foundation
import QuillSearch
import QuillWorkspace

extension AppModel {
    func runShell(_ command: String) {
        let generation = document.generation
        let root = document.rootURL
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Self.runHookProcess(command: command, root: root)
            }.value
            guard self.document.generation == generation else { return }
            switch result {
            case .open(let path, let line, let column):
                let absolute = path.hasPrefix("/") ? path : root.appendingPathComponent(path).path
                self.openTarget(LaunchTarget(path: absolute, line: line, column: column))
            case .status(let text):
                self.message = text
            }
        }
    }

    nonisolated private static func runHookProcess(command: String, root: URL) -> HookResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", command]
        proc.currentDirectoryURL = root
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        do {
            try proc.run()
        } catch {
            return .status(error.localizedDescription)
        }
        let (out, err) = ContentSearch.drain(
            stdout: stdout.fileHandleForReading,
            stderr: stderr.fileHandleForReading,
            process: proc
        )
        let outText = String(data: out, encoding: .utf8) ?? ""
        let errText = String(data: err, encoding: .utf8) ?? ""
        return ShellHook.interpret(stdout: outText, stderr: errText, status: proc.terminationStatus)
    }
}
