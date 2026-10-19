import AppKit
import QuillSearch
import QuillVim

/// Maps an engine action onto the command that performs it.
enum CommandRoutes {
    static func id(for action: HostAction) -> String? {
        switch action {
        case .write: "file.save"
        case .quit: "file.close"
        case .goToDefinition: "navigate.definition"
        case .openParentDirectory: "file.parent"
        case .openUnderCursor: "file.openEntry"
        case .findFiles: "search.files"
        case .liveGrep: "search.grep"
        case .findReferences: "navigate.references"
        case .codeAction: "navigate.codeAction"
        case .toggleTheme: "view.toggleTheme"
        case .setTheme(let choice): "view.theme.\(choice.rawValue)"
        case .writeQuit, .formatTables, .shell, .command:
            nil
        }
    }
}

extension AppModel {
    func installCommands() {
        register(
            id: "search.commands",
            name: "Command Palette…",
            category: "Search",
            bindings: [chord("k", command: true)],
            showsInMenu: true,
            menuCategory: "File"
        ) { [weak self] in
            self?.presentCommandPalette()
        }
        register(
            id: "file.new",
            name: "New",
            category: "File",
            bindings: [chord("n", command: true)],
            showsInMenu: true
        ) { [weak self] in
            self?.newUntitled()
        }
        register(
            id: "file.open",
            name: "Open…",
            category: "File",
            bindings: [chord("o", command: true)],
            showsInMenu: true
        ) { [weak self] in
            self?.openPanel()
        }
        register(
            id: "file.parent",
            name: "Open Parent Directory",
            category: "File",
            bindings: [CommandBinding(.keys("-"))],
            showsInMenu: true
        ) { [weak self] in
            self?.openParent()
        }
        register(
            id: "file.config",
            name: "Open Config",
            category: "File",
            showsInMenu: true
        ) { [weak self] in
            self?.openConfigFile()
        }
        register(
            id: "file.save",
            name: "Save",
            category: "File",
            bindings: [chord("s", command: true), CommandBinding(.ex("w"))],
            showsInMenu: true
        ) { [weak self] in
            self?.save()
        }
        register(
            id: "file.saveAs",
            name: "Save As…",
            category: "File",
            bindings: [chord("s", command: true, shift: true)],
            showsInMenu: true,
            enabled: { [weak self] in self?.isDirectory == false }
        ) { [weak self] in
            self?.saveAs()
        }
        register(
            id: "file.saveQuit",
            name: "Save and Close",
            category: "File",
            bindings: [CommandBinding(.ex("wq")), CommandBinding(.ex("x"))]
        ) { [weak self] in
            guard let self else { return }
            self.save { self.runCommand("file.close") }
        }
        register(
            id: "file.close",
            name: "Close",
            category: "File",
            bindings: [chord("w", command: true), CommandBinding(.ex("q"))],
            showsInMenu: true
        ) { [weak self] in
            guard let self else { return }
            self.closeRequests += 1
            NSApplication.shared.keyWindow?.close()
        }
        register(
            id: "file.openEntry",
            name: "Open Entry",
            category: "File",
            enabled: { [weak self] in self?.isDirectory == true }
        ) { [weak self] in
            self?.openCurrentEntry()
        }
        register(
            id: "search.files",
            name: "Find Files",
            category: "Search",
            bindings: [chord("p", command: true)] + leaderBindings(.findFiles),
            showsInMenu: true
        ) { [weak self] in
            self?.presentFilePicker()
        }
        register(
            id: "search.grep",
            name: "Live Grep",
            category: "Search",
            bindings: [chord("f", command: true, shift: true)] + leaderBindings(.liveGrep),
            showsInMenu: true
        ) { [weak self] in
            self?.presentGrepPicker()
        }
        register(
            id: "navigate.definition",
            name: "Go to Definition",
            category: "Navigate",
            bindings: [chord("d", command: true), CommandBinding(.keys("gd"))],
            showsInMenu: true
        ) { [weak self] in
            self?.goToDefinition()
        }
        register(
            id: "navigate.references",
            name: "Find References",
            category: "Navigate",
            bindings: [CommandBinding(.keys("gr"))],
            showsInMenu: true
        ) { [weak self] in
            self?.findReferences()
        }
        register(
            id: "navigate.codeAction",
            name: "Code Action",
            category: "Navigate",
            bindings: leaderBindings(.codeAction),
            showsInMenu: true
        ) { [weak self] in
            self?.presentCodeActions()
        }
        register(
            id: "view.toggleImages",
            name: "Toggle Images",
            category: "View",
            showsInMenu: true
        ) { [weak self] in
            self?.toggleImages()
        }
        register(
            id: "view.focus",
            name: "Focus Mode",
            category: "View",
            bindings: [chord("f", command: true, control: true)],
            showsInMenu: true
        ) { [weak self] in
            self?.toggleFocus()
        }
        register(
            id: "view.toggleTheme",
            name: "Toggle Light/Dark",
            category: "View",
            bindings: [chord("l", command: true, shift: true), CommandBinding(.ex("theme"))] + leaderBindings(.toggleTheme),
            showsInMenu: true
        ) { [weak self] in
            self?.toggleTheme()
        }
        register(
            id: "view.theme.light",
            name: "Theme Light",
            category: "View",
            bindings: [CommandBinding(.ex("theme light"))],
            showsInMenu: true
        ) { [weak self] in
            self?.setTheme(.light)
        }
        register(
            id: "view.theme.dark",
            name: "Theme Dark",
            category: "View",
            bindings: [CommandBinding(.ex("theme dark"))],
            showsInMenu: true
        ) { [weak self] in
            self?.setTheme(.dark)
        }
        register(
            id: "view.theme.system",
            name: "Theme System",
            category: "View",
            bindings: [CommandBinding(.ex("theme system"))],
            showsInMenu: true
        ) { [weak self] in
            self?.setTheme(.system)
        }
        register(
            id: "edit.formatTable",
            name: "Format Table",
            category: "Edit",
            bindings: [CommandBinding(.ex("TableFormat"))],
            showsInMenu: true,
            enabled: { [weak self] in self?.isDirectory == false }
        ) { [weak self] in
            self?.formatTables(startLine: nil, endLine: nil, quiet: false)
        }
        for (sequence, command) in config.shellCommands.sorted(by: { $0.key < $1.key }) where !sequence.isEmpty && !command.isEmpty {
            let id = "shell.\(sequence)"
            register(
                id: id,
                name: command,
                category: "Shell",
                bindings: [CommandBinding(.leader(sequence))]
            ) { [weak self] in
                self?.runShell(command)
            }
        }
    }

    func menuEntries(category: String) -> [CommandEntry] {
        commands.menuEntries(category: category)
    }

    func isCommandEnabled(id: String) -> Bool {
        commands.isEnabled(id: id)
    }

    @discardableResult
    func runCommand(_ id: String) -> Bool {
        commands.run(id: id)
    }

    func presentCommandPalette() {
        if paletteMode == nil {
            paletteMode = engine.mode
            paletteCursor = engine.cursor
        }
        let picker = PickerEngine()
        picker.onQueryChange = { [weak self] query in
            self?.reloadCommandPalette(query)
        }
        pickerKind = .commands
        self.picker = picker
        reloadCommandPalette(picker.query)
    }

    func reloadCommandPalette(_ query: String) {
        guard pickerKind == .commands, let picker else { return }
        let items = commands.ranked(matching: query).map { entry in
            PickerItem(
                title: entry.name,
                subtitle: CommandBinding.shortcutLabel(for: entry.bindings),
                payload: entry.id,
                dimmed: !commands.isEnabled(id: entry.id)
            )
        }
        picker.replaceItems(items, resetSelection: true)
        pickerTick += 1
    }

    func dismissCommandPalette(restore: Bool) {
        picker = nil
        pickerKind = nil
        let mode = paletteMode
        let cursor = paletteCursor
        paletteMode = nil
        paletteCursor = nil
        guard restore, let mode, let cursor else { return }
        engine.mode = mode
        if engine.cursor != cursor {
            engine.moveCursor(to: cursor)
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

    func shellCommandID(_ command: String) -> String? {
        for (sequence, action) in engine.leaderBindings {
            if case .shell(let bound) = action, bound == command {
                return "shell.\(sequence)"
            }
        }
        return nil
    }

    private func leaderBindings(_ action: HostAction) -> [CommandBinding] {
        engine.leaderBindings
            .compactMap { sequence, bound in bound == action ? sequence : nil }
            .sorted()
            .map { CommandBinding(.leader($0)) }
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
        perform: @escaping () -> Void
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
