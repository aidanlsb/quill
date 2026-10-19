/// `system` follows the macOS appearance. A runtime toggle leaves `system` for an explicit side.
enum ThemeChoice: String, Equatable, Sendable {
    case system
    case light
    case dark

    static func parse(_ text: String) -> ThemeChoice? {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "system": return .system
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    /// A remembered runtime choice wins. Config applies when nothing has been chosen yet.
    static func resolved(config: ThemeChoice, remembered: ThemeChoice?) -> ThemeChoice {
        remembered ?? config
    }

    func toggled(systemIsDark: Bool) -> ThemeChoice {
        switch self {
        case .light: return .dark
        case .dark: return .light
        case .system: return systemIsDark ? .light : .dark
        }
    }

    func isDark(systemIsDark: Bool) -> Bool {
        switch self {
        case .dark: return true
        case .light: return false
        case .system: return systemIsDark
        }
    }
}
