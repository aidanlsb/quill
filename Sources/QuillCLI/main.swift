import Foundation
import QuillWorkspace

@main
enum QuillCLI {
    static func main() {
        let environment = ProcessInfo.processInfo.environment
        let code = QuillCommand.run(
            arguments: Array(CommandLine.arguments.dropFirst()),
            environment: environment,
            cwd: FileManager.default.currentDirectoryPath,
            send: { targets in
                InstanceClient.send(targets, socket: InstanceSocket.path(environment: environment))
            },
            openApp: { app, urls, wait in
                openApp(app, urls: urls, wait: wait)
            }
        )
        if code != 0, !CommandLine.arguments.contains("--wait") {
            FileHandle.standardError.write(Data("quill: could not launch Quill\n".utf8))
        }
        exit(code)
    }
}

private func openApp(_ app: String, urls: [String], wait: Bool) -> Int32 {
    var args: [String] = []
    if wait {
        args.append(contentsOf: ["-W", "-n", "-a", app, "--args", "--quill-standalone"])
    } else if urls.first == "--quill-socket" {
        // Flags after the bundle are for Quill, not for `open`.
        args.append(contentsOf: ["-a", app, "--args"])
    } else {
        args.append(contentsOf: ["-a", app])
    }
    args.append(contentsOf: urls)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = args
    do {
        try process.run()
    } catch {
        return 1
    }
    process.waitUntilExit()
    return process.terminationStatus
}
