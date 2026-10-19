import AppKit
import QuillSearch
import QuillVim

extension AppModel {
    func installCommands() {
        register(
            id: "search.commands",
            name: "Command Palette…",
            category: "Search",
            bindings: [chord("k", command: true)],
            showsInMenu: true,
            menuCategory: "File"
        ) { [weak self] _ in
            self?.presentCommandPalette()
        }
        register(
            id: "file.new",
            name: "New",
            category: "File",
            bindings: [chord("n", command: true)],
            showsInMenu: true
        ) { [weak self] _ in
            self?.newUntitled()
        }
        register(
            id: "file.open",
            name: "Open…",
            category: "File",
            bindings: [chord("o", command: true)],
            showsInMenu: true
        ) { [weak self] _ in
            self?.openPanel()
        }
        register(
            id: "file.parent",
            name: "Open Parent Directory",
            category: "File",
            bindings: [CommandBinding(.keys("-"))],
            showsInMenu: true
        ) { [weak self] _ in
            self?.openParent()
        }
        register(
            id: "file.config",
            name: "Open Config",
            category: "File",
            showsInMenu: true
        ) { [weak self] _ in
            self?.openConfigFile()
        }
        register(
            id: "file.save",
            name: "Save",
            category: "File",
            bindings: [chord("s", command: true), CommandBinding(.ex("w")), CommandBinding(.ex("write"))],
            showsInMenu: true
        ) { [weak self] args in
            guard let self else { return }
            if args.text.isEmpty {
                self.save()
            } else {
                self.save(toPath: args.text)
            }
        }
        register(
            id: "file.saveAs",
            name: "Save As…",
            category: "File",
            bindings: [chord("s", command: true, shift: true)],
            showsInMenu: true,
            enabled: { [weak self] in self?.isDirectory == false }
        ) { [weak self] _ in
            self?.saveAs()
        }
        register(
            id: "file.saveQuit",
            name: "Save and Close",
            category: "File",
            bindings: [CommandBinding(.ex("wq")), CommandBinding(.ex("x"))]
        ) { [weak self] _ in
            guard let self else { return }
            self.save { self.runCommand("file.close") }
        }
        register(
            id: "file.close",
            name: "Close",
            category: "File",
            bindings: [chord("w", command: true), CommandBinding(.ex("q")), CommandBinding(.ex("quit"))],
            showsInMenu: true
        ) { [weak self] args in
            self?.close(bang: args.bang)
        }
        register(
            id: "file.edit",
            name: "Reload / Edit",
            category: "File",
            bindings: [CommandBinding(.ex("e")), CommandBinding(.ex("edit"))]
        ) { [weak self] args in
            self?.edit(args)
        }
        register(
            id: "file.openEntry",
            name: "Open Entry",
            category: "File",
            bindings: [CommandBinding(.keys("<CR>"))],
            enabled: { [weak self] in self?.isDirectory == true }
        ) { [weak self] _ in
            self?.openCurrentEntry()
        }
        register(
            id: "search.files",
            name: "Find Files",
            category: "Search",
            bindings: [chord("p", command: true), CommandBinding(.leader("sf"))],
            showsInMenu: true
        ) { [weak self] _ in
            self?.presentFilePicker()
        }
        register(
            id: "search.grep",
            name: "Live Grep",
            category: "Search",
            bindings: [chord("f", command: true, shift: true), CommandBinding(.leader("sg"))],
            showsInMenu: true
        ) { [weak self] _ in
            self?.presentGrepPicker()
        }
        register(
            id: "navigate.definition",
            name: "Go to Definition",
            category: "Navigate",
            bindings: [chord("d", command: true), CommandBinding(.keys("gd"))],
            showsInMenu: true
        ) { [weak self] _ in
            self?.goToDefinition()
        }
        register(
            id: "navigate.hover",
            name: "Show Info Under Cursor",
            category: "Navigate",
            bindings: [CommandBinding(.keys("K"))],
            showsInMenu: true
        ) { [weak self] _ in
            self?.showHover()
        }
        register(
            id: "navigate.references",
            name: "Find References",
            category: "Navigate",
            bindings: [CommandBinding(.keys("gr"))],
            showsInMenu: true
        ) { [weak self] _ in
            self?.findReferences()
        }
        register(
            id: "navigate.codeAction",
            name: "Code Action",
            category: "Navigate",
            bindings: [CommandBinding(.leader("ca"))],
            showsInMenu: true
        ) { [weak self] _ in
            self?.presentCodeActions()
        }
        register(
            id: "view.toggleImages",
            name: "Toggle Images",
            category: "View",
            showsInMenu: true
        ) { [weak self] _ in
            self?.toggleImages()
        }
        register(
            id: "view.focus",
            name: "Focus Mode",
            category: "View",
            bindings: [chord("f", command: true, control: true)],
            showsInMenu: true
        ) { [weak self] _ in
            self?.toggleFocus()
        }
        register(
            id: "view.toggleTheme",
            name: "Toggle Light/Dark",
            category: "View",
            bindings: [chord("l", command: true, shift: true), CommandBinding(.leader("tt"))],
            showsInMenu: true
        ) { [weak self] _ in
            self?.toggleTheme()
        }
        register(
            id: "view.theme",
            name: "Set Theme",
            category: "View",
            bindings: [CommandBinding(.ex("theme"))]
        ) { [weak self] args in
            guard let self else { return }
            if args.text.isEmpty {
                self.toggleTheme()
                return
            }
            guard let choice = ThemeChoice.parse(args.text) else {
                self.message = "theme must be light, dark, or system"
                NSSound.beep()
                return
            }
            self.setTheme(choice)
        }
        register(
            id: "view.theme.light",
            name: "Theme Light",
            category: "View",
            showsInMenu: true
        ) { [weak self] _ in
            self?.setTheme(.light)
        }
        register(
            id: "view.theme.dark",
            name: "Theme Dark",
            category: "View",
            showsInMenu: true
        ) { [weak self] _ in
            self?.setTheme(.dark)
        }
        register(
            id: "view.theme.system",
            name: "Theme System",
            category: "View",
            showsInMenu: true
        ) { [weak self] _ in
            self?.setTheme(.system)
        }
        register(
            id: "edit.formatTable",
            name: "Format Table",
            category: "Edit",
            bindings: [CommandBinding(.ex("TableFormat"))],
            showsInMenu: true,
            enabled: { [weak self] in self?.isDirectory == false }
        ) { [weak self] args in
            guard let self else { return }
            if !args.text.isEmpty {
                self.message = "Not an editor command: TableFormat"
                NSSound.beep()
                return
            }
            if let lines = args.lines {
                self.formatTables(startLine: lines.lowerBound, endLine: lines.upperBound, quiet: false)
            } else {
                self.formatTables(startLine: nil, endLine: nil, quiet: false)
            }
        }
        for (sequence, command) in config.shellCommands.sorted(by: { $0.key < $1.key }) where !sequence.isEmpty && !command.isEmpty {
            let id = "shell.\(sequence)"
            register(
                id: id,
                name: command,
                category: "Shell",
                bindings: [CommandBinding(.leader(sequence))]
            ) { [weak self] _ in
                self?.runShell(command)
            }
        }
        rebuildKeymap()
    }

    func menuEntries(category: String) -> [CommandEntry] {
        commands.menuEntries(category: category)
    }

    func isCommandEnabled(id: String) -> Bool {
        commands.isEnabled(id: id)
    }

    @discardableResult
    func runCommand(_ id: String, args: CommandArgs = .none) -> Bool {
        commands.run(id: id, args: args)
    }

    /// `<CR>` opens a directory entry and moves down in a file.
    func rebuildKeymap() {
        let directory = isDirectory
        engine.keymap = commands.keymap(leader: engine.leaderKey) { id in
            if id == "file.openEntry" { return directory }
            return true
        }
    }

    func presentCommandPalette() {
        let restore: (Mode, Int)?
        if case .picker(let opened) = prompt, opened.kind == .commands {
            restore = opened.restore
        } else {
            restore = (engine.mode, engine.cursor)
        }
        let token = beginPromptWork()
        let picker = PickerEngine()
        picker.onQueryChange = { [weak self] query in
            self?.reloadCommandPalette(query)
        }
        prompt = .picker(PickerSession(id: token, kind: .commands, picker: picker, restore: restore))
        reloadCommandPalette(picker.query)
    }

    func reloadCommandPalette(_ query: String) {
        guard case .picker(let opened) = prompt, opened.kind == .commands else { return }
        let items = commands.ranked(matching: query).map { entry in
            PickerItem(
                title: entry.name,
                subtitle: entry.bindings.map(\.label).joined(separator: " "),
                payload: entry.id,
                dimmed: !commands.isEnabled(id: entry.id)
            )
        }
        opened.picker.replaceItems(items, resetSelection: true)
    }

    func dismissCommandPalette(restore: Bool) {
        let restoreState: (Mode, Int)?
        if case .picker(let opened) = prompt, opened.kind == .commands {
            restoreState = opened.restore
        } else {
            restoreState = nil
        }
        clearPrompt()
        guard restore, let restoreState else { return }
        engine.mode = restoreState.0
        if engine.cursor != restoreState.1 {
            engine.moveCursor(to: restoreState.1)
        }
        status = engine.mode.displayName
    }

    func openConfigFile() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent(".config/quill/config.toml")
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                try config.tomlSource().write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            message = error.localizedDescription
            return
        }
        open(url: url)
    }

    private func chord(
        _ key: Character,
        command: Bool = false,
        shift: Bool = false,
        option: Bool = false,
        control: Bool = false
    ) -> CommandBinding {
        CommandBinding(.chord(key: key, command: command, shift: shift, option: option, control: control))
    }

    private func register(
        id: String,
        name: String,
        category: String,
        bindings: [CommandBinding] = [],
        showsInMenu: Bool = false,
        menuCategory: String? = nil,
        enabled: @escaping () -> Bool = { true },
        perform: @escaping (CommandArgs) -> Void
    ) {
        commands.register(
            id: id,
            name: name,
            category: category,
            bindings: bindings,
            showsInMenu: showsInMenu,
            menuCategory: menuCategory,
            enabled: enabled,
            perform: perform
        )
    }
}
