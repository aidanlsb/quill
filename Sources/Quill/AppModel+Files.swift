import AppKit
import UniformTypeIdentifiers
import QuillFS
import QuillMarkdown
import QuillSearch
import QuillVim
import QuillWorkspace

extension AppModel {
    func open(url: URL, immediate: Bool = false) {
        if let target = LaunchRequest.target(from: url) {
            openTarget(target, immediate: immediate)
            return
        }
        openTarget(LaunchTarget(path: url.path), immediate: immediate)
    }

    /// Last parsed launch argument wins. `open` delivers `quill://` URLs separately.
    func consumeLaunchArguments(_ arguments: [String], immediate: Bool = false) {
        guard let target = LaunchRequest.parse(arguments).last else { return }
        openTarget(target, immediate: immediate)
    }

    func openTarget(_ target: LaunchTarget, immediate: Bool = false) {
        let path = LaunchRequest.standardized(target.path)
        if LaunchRequest.sameFile(open: document.url?.path, isDirectory: document.isDirectory, target: path) {
            jump(to: target)
            return
        }
        let url = URL(fileURLWithPath: path)
        document.noteJump(target, forPath: path)
        switch NavigationGuard.decide(isModified: document.engine.isModified, force: false) {
        case .prompt(let text):
            presentUnsaved(.open(url), message: text)
        case .allow:
            beginOpen(url, immediate: immediate)
        }
    }

    func openDirectory(_ url: URL) {
        switch NavigationGuard.decide(isModified: document.engine.isModified && document.isDirectory, force: false) {
        case .prompt(let text):
            presentUnsaved(.open(url), message: text)
            return
        case .allow:
            break
        }
        if let error = document.loadDirectory(url) {
            message = error
        }
    }

    func newUntitled() {
        switch NavigationGuard.decide(isModified: document.engine.isModified, force: false) {
        case .prompt(let text):
            presentUnsaved(.newFile, message: text)
        case .allow:
            document.newUntitled()
        }
    }

    func presentUnsaved(_ navigation: PendingNavigation, message text: String) {
        session.promptEpoch += 1
        message = text
        prompt = .unsaved(navigation)
    }

    func discardAndContinue() {
        document.markClean()
        let pending: PendingNavigation?
        if case .unsaved(let navigation) = prompt { pending = navigation } else { pending = nil }
        clearPrompt()
        switch pending {
        case .open(let url):
            beginOpen(url)
        case .newFile:
            document.newUntitled()
        case .close(let window):
            window.close()
        case .terminate:
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        case nil:
            break
        }
    }

    func cancelNavigation() {
        let pending: PendingNavigation?
        if case .unsaved(let navigation) = prompt { pending = navigation } else { pending = nil }
        clearPrompt()
        if case .open(let url) = pending {
            document.cancelJump(for: url)
        }
        if case .terminate = pending {
            NSApplication.shared.reply(toApplicationShouldTerminate: false)
        }
    }

    func saveAndContinue() {
        save()
        if !document.engine.isModified {
            discardAndContinue()
        }
    }

    func requestClose(_ window: NSWindow) -> Bool {
        switch NavigationGuard.decide(isModified: document.engine.isModified, force: false) {
        case .allow:
            return true
        case .prompt(let text):
            presentUnsaved(.close(window), message: text)
            return false
        }
    }

    func requestTerminate() -> NSApplication.TerminateReply {
        switch NavigationGuard.decide(isModified: document.engine.isModified, force: false) {
        case .allow:
            return .terminateNow
        case .prompt(let text):
            presentUnsaved(.terminate, message: text)
            return .terminateLater
        }
    }

    func close(bang: Bool) {
        if !bang && document.engine.isModified {
            message = "No write since last change"
            NSSound.beep()
            return
        }
        if bang { document.markClean() }
        session.closeRequests += 1
        NSApplication.shared.keyWindow?.close()
    }

    func edit(_ args: CommandArgs) {
        if !args.text.isEmpty {
            if document.engine.isModified && !args.bang {
                message = "No write since last change"
                NSSound.beep()
                return
            }
            open(url: document.resolve(args.text))
            return
        }
        guard document.url != nil else {
            message = "No file"
            NSSound.beep()
            return
        }
        if document.engine.isModified && !args.bang {
            message = "No write since last change"
            NSSound.beep()
            return
        }
        let generation = document.generation
        Task {
            do {
                let installed = try await self.document.reload()
                guard installed, self.document.generation != generation else { return }
                self.message = "Reloaded"
            } catch {
                self.message = error.localizedDescription
            }
        }
    }

    func save(toPath path: String) {
        let url = document.resolve(path)
        if document.url == nil {
            document.claimUntitled(url)
            save()
            return
        }
        if document.url?.standardizedFileURL.path == url.standardizedFileURL.path {
            save()
            return
        }
        let ending: LineEnding
        if case .file(_, let current, _) = document.kind { ending = current } else { ending = .lf }
        let data = TextCodec.encode(document.engine.text, ending: ending)
        let generation = document.generation
        let write = document.diskWrite
        Task {
            do {
                try await write(data, url)
                guard self.document.generation == generation else { return }
                self.message = "Saved"
            } catch {
                guard self.document.generation == generation else { return }
                self.message = error.localizedDescription
            }
        }
    }

    func save(then completion: (@MainActor () -> Void)? = nil) {
        if document.isDirectory {
            if let bad = DirectoryListing.invalidName(in: document.listingLines()) {
                message = "Invalid name: \(bad)"
                NSSound.beep()
                return
            }
            let ops = document.planDirectorySave()
            if ops.isEmpty {
                document.markClean()
                message = "No filesystem changes"
                if !document.engine.isModified { completion?() }
                return
            }
            session.promptEpoch += 1
            prompt = .confirmFilesystem(
                ops: ops,
                warning: DirectoryListing.mixesDeletesAndCreates(ops)
                    ? "This save both deletes and creates files. Check the names before applying."
                    : ""
            )
            return
        }
        switch document.prepareSave() {
        case .noFile:
            saveAs()
        case .conflict:
            message = "File changed on disk. Save again to overwrite."
        case .ready(let request):
            let generation = request.generation
            Task {
                do {
                    switch try await self.document.finishSave(request) {
                    case .saved(let text):
                        self.lspDidSave(text, generation: generation)
                        self.message = "Saved"
                        guard !self.document.engine.isModified else { return }
                        if case .unsaved = self.prompt {
                            self.discardAndContinue()
                        } else {
                            completion?()
                        }
                    case .conflict, .noFile, .superseded:
                        break
                    }
                } catch {
                    guard self.document.generation == generation, self.document.url == request.url else { return }
                    self.message = error.localizedDescription
                }
            }
        }
    }

    func applyPendingOps() {
        guard case .confirmFilesystem(let ops, _) = prompt else { return }
        if let bad = DirectoryListing.invalidName(in: document.listingLines()) {
            message = "Invalid name: \(bad)"
            return
        }
        if let snapshot = document.snapshot, let problem = DirectoryListing.confinementError(ops, directory: snapshot.directory) {
            message = problem
            return
        }
        do {
            if let error = try document.applyDirectoryOps(ops) {
                message = error
                return
            }
        } catch let error as FSExecutionError {
            message = "\(error.failed): \(error.message)"
            return
        } catch {
            message = error.localizedDescription
            return
        }
        clearPrompt()
        message = "Applied"
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "untitled.md"
        panel.begin { [weak self] response in
            Task { @MainActor [weak self] in
                guard let self, response == .OK, let url = panel.url else { return }
                self.document.claimUntitled(url)
                self.save()
            }
        }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            Task { @MainActor [weak self] in
                guard let self, response == .OK, let url = panel.url else { return }
                self.open(url: url)
            }
        }
    }

    func openParent() {
        let base = document.url ?? document.rootURL
        if document.isDirectory {
            let parent = base.deletingLastPathComponent()
            if parent.path != base.path { openDirectory(parent) }
            return
        }
        openDirectory(base.deletingLastPathComponent())
    }

    func openCurrentEntry() {
        guard document.isDirectory, let snap = document.snapshot else { return }
        let line = document.engine.lineTextUnderCursor()
        let parsed = ParsedDirLine(line)
        guard let dest = DirectoryName.child(snap.directory, parsed.name) else {
            message = "Invalid name"
            NSSound.beep()
            return
        }
        open(url: dest)
    }

    func beginOpen(_ url: URL, immediate: Bool = false) {
        let began = StartupProbe.begin("openSyncMs")
        let installed: Bool
        do {
            installed = try document.openSynchronously(url)
        } catch {
            StartupProbe.end("openSyncMs", began)
            message = error.localizedDescription
            return
        }
        StartupProbe.end("openSyncMs", began)
        if installed { return }
        if immediate {
            do {
                try document.readImmediately(url)
            } catch {
                message = error.localizedDescription
            }
            return
        }
        Task {
            do {
                _ = try await self.document.open(url)
            } catch {
                self.message = error.localizedDescription
            }
        }
    }

    func formatTables(startLine: Int?, endLine: Int?, quiet: Bool) {
        guard !document.isDirectory else { return }
        let scope: TableScope
        if let startLine, let endLine {
            scope = .lines(min(startLine, endLine)...max(startLine, endLine))
        } else {
            scope = .cursor
        }
        let plan = MarkdownTables.plan(
            in: document.engine.text,
            scope: scope,
            cursor: document.engine.cursor
        )
        guard plan.matched else {
            if !quiet { message = "Not a table" }
            return
        }
        guard !plan.rewrites.isEmpty else { return }
        let edits = plan.rewrites.map { TextEdit(range: $0.range, replacement: $0.replacement) }
        apply(document.engine.applyHostEdits(edits, cursor: plan.cursor))
    }
}
