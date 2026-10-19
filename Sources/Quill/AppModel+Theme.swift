import AppKit

extension AppModel {
    convenience init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let loaded = QuillConfig.loadReporting()
        let choice = ThemeChoice.resolved(
            config: loaded.config.theme,
            remembered: ThemeMemory.load(from: ThemeMemory.url(home: home))
        )
        self.init(
            config: loaded.config,
            home: home,
            notice: loaded.error,
            isDark: {
                let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
                return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            }
        )
        themeChoice = choice
        theme = makeTheme(choice)
        session.appearanceObserver = NSApplication.shared.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.themeChoice == .system else { return }
                self.applyTheme(self.themeChoice, remember: false)
            }
        }
    }

    func setTheme(_ choice: ThemeChoice) {
        applyTheme(choice, remember: true)
    }

    func toggleTheme() {
        applyTheme(themeChoice.toggled(systemIsDark: session.isDark()), remember: true)
    }

    func applyTheme(_ choice: ThemeChoice, remember: Bool) {
        themeChoice = choice
        theme = makeTheme(choice)
        themeIdentity += 1
        guard remember else { return }
        message = "theme \(choice.rawValue)"
        let url = ThemeMemory.url(home: session.home)
        do {
            try ThemeMemory.save(choice, to: url)
        } catch {
            message = "theme \(choice.rawValue) (\(error.localizedDescription))"
        }
    }

    func makeTheme(_ choice: ThemeChoice) -> QuillTheme {
        QuillTheme.current(
            fontFamily: config.font,
            fontSize: config.fontSize,
            columnCharacters: config.columnWidth,
            scheme: choice,
            systemIsDark: session.isDark()
        )
    }
}
