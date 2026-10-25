import Foundation

/// Where the app bundle is. `QUILL_APP` wins. Otherwise `/Applications/Quill.app`, then `dist` and `.build` under `cwd`.
public enum AppLocation {
    public static func resolve(environment: [String: String], cwd: String) -> String? {
        if let given = environment["QUILL_APP"], !given.isEmpty, given != "Quill" {
            return absolute(given, cwd: cwd)
        }
        let candidates = [
            "/Applications/Quill.app",
            join(cwd, "dist/Quill.app"),
            join(cwd, ".build/Quill.app"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private static func absolute(_ path: String, cwd: String) -> String {
        path.hasPrefix("/") ? path : join(cwd, path)
    }

    private static func join(_ cwd: String, _ relative: String) -> String {
        if relative.hasPrefix("/") { return relative }
        if cwd == "/" { return "/" + relative }
        if cwd.hasSuffix("/") { return cwd + relative }
        return cwd + "/" + relative
    }
}

public enum LaunchAction: Equatable {
    case running
    /// The socket accepted a connection and did not take the paths. Do not start another process.
    case rejected
    case open(app: String, urls: [String], wait: Bool)
}

/// A live instance gets the paths over the socket. Cold launches use `open -a`.
public enum QuillCommand {
    public static func run(
        arguments: [String],
        environment: [String: String],
        cwd: String,
        send: ([LaunchTarget]) -> HandoffResult,
        openApp: (String, [String], Bool) -> Int32
    ) -> Int32 {
        let wait = arguments.first == "--wait"
        let userArgs = wait ? Array(arguments.dropFirst()) : arguments
        let targets: [LaunchTarget]
        do {
            targets = try LaunchRequest.prepare(userArgs, cwd: cwd)
        } catch {
            return 1
        }
        let bundle = AppLocation.resolve(environment: environment, cwd: cwd)
        let handoff: HandoffResult = wait ? .notRunning : send(targets)
        let action = plan(
            targets: targets,
            environment: environment,
            handoff: handoff,
            bundle: bundle,
            wait: wait
        )
        switch action {
        case .running:
            mark(environment, "handoff")
            return 0
        case .rejected:
            mark(environment, "rejected")
            return 1
        case .open(let app, let urls, let shouldWait):
            mark(environment, "open")
            return openApp(app, urls, shouldWait)
        }
    }

    static func plan(
        targets: [LaunchTarget],
        environment: [String: String],
        handoff: HandoffResult,
        bundle: String?,
        wait: Bool
    ) -> LaunchAction {
        if !wait, handoff == .delivered {
            return .running
        }
        if !wait, handoff == .failed {
            return .rejected
        }
        var urls = LaunchRequest.urls(for: targets)
        // `open` drops the environment. The private socket still has to reach the app.
        if !wait, let socket = environment["QUILL_SOCKET"], !socket.isEmpty {
            urls.insert("--quill-socket", at: 0)
            urls.insert(socket, at: 1)
        }
        return .open(app: bundle ?? "Quill", urls: urls, wait: wait)
    }

    private static func mark(_ environment: [String: String], _ word: String) {
        guard environment["QUILL_LAUNCH_MARK"] == "1" else { return }
        FileHandle.standardError.write(Data("quill launch \(word)\n".utf8))
    }
}
