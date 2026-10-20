import Darwin
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
            spawn: { binary, arguments, environment, wait in
                DetachedSpawn.launch(binary: binary, arguments: arguments, environment: environment, wait: wait)
            },
            openApp: { app, urls, wait in
                openApp(app, urls: urls, wait: wait)
            }
        )
        if code != 0 {
            FileHandle.standardError.write(Data("quill: could not launch Quill\n".utf8))
        }
        exit(code)
    }
}

/// New session, stdio to `/dev/null`, and this process is not the TCC responsible
/// process for the editor. Closing the terminal does not deliver SIGHUP.
enum DetachedSpawn {
    static func launch(binary: String, arguments: [String], environment: [String: String], wait: Bool) -> Int32? {
        // Disclaim can make posix_spawn return EINVAL. A failed attempt does not
        // create a process, so the next attempt is the one that runs.
        var last = Int32(EINVAL)
        for disclaimResponsibility in [true, false] {
            if let status = spawn(
                binary: binary,
                arguments: arguments,
                environment: environment,
                wait: wait,
                disclaimResponsibility: disclaimResponsibility,
                error: &last
            ) {
                return status
            }
        }
        FileHandle.standardError.write(Data("quill: spawn failed \(last)\n".utf8))
        return nil
    }

    private static func spawn(
        binary: String,
        arguments: [String],
        environment: [String: String],
        wait: Bool,
        disclaimResponsibility: Bool,
        error: inout Int32
    ) -> Int32? {
        var actions: posix_spawn_file_actions_t?
        var attrs: posix_spawnattr_t?
        let actionsReady = posix_spawn_file_actions_init(&actions)
        if actionsReady != 0 {
            error = actionsReady
            return nil
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        let attrsReady = posix_spawnattr_init(&attrs)
        if attrsReady != 0 {
            error = attrsReady
            return nil
        }
        defer { posix_spawnattr_destroy(&attrs) }

        let flags = Int16(POSIX_SPAWN_SETSID)
        let flagged = posix_spawnattr_setflags(&attrs, flags)
        if flagged != 0 {
            error = flagged
            return nil
        }
        if disclaimResponsibility {
            disclaim(&attrs)
        }

        if posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0) != 0
            || posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0) != 0
            || posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0) != 0
        {
            error = errno
            return nil
        }

        var argv = arguments.map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }
        let pairs = environment.map { "\($0.key)=\($0.value)" }.sorted()
        var envp = pairs.map { strdup($0) }
        envp.append(nil)
        defer { envp.forEach { free($0) } }
        if argv.contains(where: { $0 == nil }) || envp.contains(where: { $0 == nil }) {
            error = Int32(ENOMEM)
            return nil
        }

        var pid: pid_t = 0
        let spawned = argv.withUnsafeBufferPointer { argvBuf in
            envp.withUnsafeBufferPointer { envBuf in
                posix_spawn(&pid, binary, &actions, &attrs, argvBuf.baseAddress, envBuf.baseAddress)
            }
        }
        if spawned != 0 || pid <= 0 {
            error = spawned == 0 ? Int32(ECHILD) : spawned
            return nil
        }
        guard wait else { return 0 }
        while true {
            var status: Int32 = 0
            let waited = waitpid(pid, &status, 0)
            if waited == pid {
                // wait.h WIFEXITED / WEXITSTATUS. Swift does not import those macros.
                if status & 0x7f == 0 { return (status >> 8) & 0xff }
                return 1
            }
            if errno == EINTR { continue }
            return 1
        }
    }

    /// `responsibility_spawnattrs_setdisclaim` is not in the public SDK. When it
    /// is present, file-access prompts name Quill rather than the terminal.
    private static func disclaim(_ attrs: inout posix_spawnattr_t?) {
        // RTLD_DEFAULT is ((void *) -2). The macro is not imported into Swift.
        guard let image = UnsafeMutableRawPointer(bitPattern: -2),
              let symbol = dlsym(image, "responsibility_spawnattrs_setdisclaim") else { return }
        typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
        let function = unsafeBitCast(symbol, to: Disclaim.self)
        _ = function(&attrs, 1)
    }
}

private func openApp(_ app: String, urls: [String], wait: Bool) -> Int32 {
    var args: [String] = []
    if wait {
        args.append(contentsOf: ["-W", "-n", "-a", app, "--args", "--quill-standalone"])
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
