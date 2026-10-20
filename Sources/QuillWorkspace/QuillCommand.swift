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

    public static func executable(in bundle: String) -> String {
        let trimmed = bundle.hasSuffix("/") ? String(bundle.dropLast()) : bundle
        return trimmed + "/Contents/MacOS/Quill"
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

/// The shell environment the editor (and the language servers it spawns) inherits.
/// `PATH` is kept. Injected libraries and credential-shaped variables are not.
public enum LaunchEnvironment {
    public static let defaultPath = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"

    public static func sanitize(_ environment: [String: String]) -> [String: String] {
        var kept: [String: String] = [:]
        for (key, value) in environment where !shouldDrop(key) {
            kept[key] = value
        }
        if kept["PATH"]?.isEmpty != false {
            kept["PATH"] = defaultPath
        }
        return kept
    }

    public static func shouldDrop(_ key: String) -> Bool {
        if key.hasPrefix("DYLD_") || key == "LD_PRELOAD" { return true }
        if key.hasPrefix("GITHUB_") || key.hasPrefix("GH_") { return true }
        if key.hasPrefix("AWS_") || key.hasPrefix("AZURE_") || key.hasPrefix("NPM_") { return true }
        if droppedExact.contains(key) { return true }
        let upper = key.uppercased()
        if upper.contains("TOKEN") || upper.contains("SECRET") || upper.contains("PASSWORD") || upper.contains("CREDENTIAL") {
            return true
        }
        return false
    }

    private static let droppedExact: Set<String> = [
        "QUILL_SMOKE", "QUILL_PERF", "QUILL_STARTUP", "QUILL_STARTUP_OUT", "QUILL_STARTUP_FIFO", "QUILL_LAUNCH_MARK",
    ]
}

public enum LaunchAction: Equatable {
    case running
    /// The socket accepted a connection and did not take the paths. Do not start another process.
    case rejected
    case spawn(binary: String, arguments: [String], environment: [String: String], wait: Bool)
    case open(app: String, urls: [String], wait: Bool)
}

/// `quill` with no running instance spawns the bundle executable.
/// A live instance gets the paths over the socket. `open -a` is the fallback.
public enum QuillCommand {
    public static func run(
        arguments: [String],
        environment: [String: String],
        cwd: String,
        send: ([LaunchTarget]) -> HandoffResult,
        spawn: (String, [String], [String: String], Bool) -> Int32?,
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
        let binary = bundle.map { AppLocation.executable(in: $0) }
        let canSpawn = binary.map { FileManager.default.isExecutableFile(atPath: $0) } ?? false
        let handoff: HandoffResult = wait ? .notRunning : send(targets)
        let action = plan(
            targets: targets,
            environment: environment,
            handoff: handoff,
            bundle: bundle,
            binary: binary,
            canSpawn: canSpawn,
            wait: wait
        )
        switch action {
        case .running:
            mark(environment, "handoff")
            return 0
        case .rejected:
            mark(environment, "rejected")
            return 1
        case .spawn(let path, let args, let env, let shouldWait):
            if let status = spawn(path, args, env, shouldWait) {
                mark(environment, shouldWait ? "wait" : "direct")
                return status
            }
            mark(environment, "open")
            let fallback = openArguments(targets: targets, bundle: bundle, wait: wait)
            return openApp(fallback.app, fallback.urls, fallback.wait)
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
        binary: String?,
        canSpawn: Bool,
        wait: Bool
    ) -> LaunchAction {
        if !wait, handoff == .delivered {
            return .running
        }
        if !wait, handoff == .failed {
            return .rejected
        }
        if canSpawn, let binary {
            var env = LaunchEnvironment.sanitize(environment)
            env["QUILL_FOREGROUND"] = "1"
            if wait { env["QUILL_STANDALONE"] = "1" }
            var args = [binary]
            if wait { args.append("--quill-standalone") }
            if let socket = environment["QUILL_SOCKET"], !socket.isEmpty {
                args.append("--quill-socket")
                args.append(socket)
            }
            args.append(contentsOf: LaunchRequest.urls(for: targets))
            return .spawn(binary: binary, arguments: args, environment: env, wait: wait)
        }
        let open = openArguments(targets: targets, bundle: bundle, wait: wait)
        return .open(app: open.app, urls: open.urls, wait: open.wait)
    }

    private static func openArguments(targets: [LaunchTarget], bundle: String?, wait: Bool) -> (app: String, urls: [String], wait: Bool) {
        (bundle ?? "Quill", LaunchRequest.urls(for: targets), wait)
    }

    private static func mark(_ environment: [String: String], _ word: String) {
        guard environment["QUILL_LAUNCH_MARK"] == "1" else { return }
        FileHandle.standardError.write(Data("quill launch \(word)\n".utf8))
    }
}
