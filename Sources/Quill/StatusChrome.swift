import AppKit
import QuillVim

/// Status line: a jewel-like mode pill, the document title, a message, and
/// the cursor as `line:column`. Keyboard-first; no widgets besides type.
@MainActor
final class StatusChrome: NSView {
    private let pill = ModePillView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let positionLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        titleLabel.lineBreakMode = .byTruncatingTail
        messageLabel.lineBreakMode = .byTruncatingTail
        positionLabel.alignment = .right
        positionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        for label in [titleLabel, messageLabel, positionLabel] {
            label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            addSubview(label)
        }
        addSubview(pill)
    }

    required init?(coder: NSCoder) { nil }

    func apply(
        theme: QuillTheme,
        directory: Bool,
        mode: String,
        title: String,
        modified: Bool,
        message: String,
        position: String,
        leading: CGFloat
    ) {
        let background = directory ? theme.directoryBackgroundColor : theme.backgroundColor
        layer?.backgroundColor = background.cgColor
        pill.apply(mode: mode, theme: theme)
        let shownTitle = modified ? "\(title)  ·" : title
        if titleLabel.stringValue != shownTitle { titleLabel.stringValue = shownTitle }
        if messageLabel.stringValue != message { messageLabel.stringValue = message }
        if positionLabel.stringValue != position { positionLabel.stringValue = position }
        titleLabel.textColor = theme.dimColor
        messageLabel.textColor = theme.dimColor
        positionLabel.textColor = theme.dimColor
        layoutChrome(leading: leading)
    }

    private func layoutChrome(leading: CGFloat) {
        let bounds = self.bounds
        let pillSize = pill.intrinsicContentSize
        let pillY = floor((bounds.height - pillSize.height) / 2)
        pill.frame = NSRect(x: leading, y: pillY, width: pillSize.width, height: pillSize.height)
        let posWidth: CGFloat = 72
        let posX = max(pill.frame.maxX + 12, bounds.width - leading - posWidth)
        positionLabel.frame = NSRect(x: posX, y: 7, width: posWidth, height: 16)
        let titleX = pill.frame.maxX + 12
        let titleWidth = max(48, posX - titleX - 12)
        if messageLabel.stringValue.isEmpty {
            messageLabel.frame = .zero
            titleLabel.frame = NSRect(x: titleX, y: 7, width: titleWidth, height: 16)
        } else {
            let half = titleWidth * 0.42
            titleLabel.frame = NSRect(x: titleX, y: 7, width: half, height: 16)
            messageLabel.frame = NSRect(
                x: titleX + half + 8,
                y: 7,
                width: max(32, titleWidth - half - 8),
                height: 16
            )
        }
    }
}

@MainActor
final class ModePillView: NSView {
    private let label = NSTextField(labelWithString: "NORMAL")

    override var intrinsicContentSize: NSSize {
        let text = label.intrinsicContentSize
        return NSSize(width: ceil(text.width) + 14, height: QuillMetrics.modePillHeight)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
        label.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        label.alignment = .center
        addSubview(label)
        setAccessibilityIdentifier("quill.status.mode")
    }

    required init?(coder: NSCoder) { nil }

    func apply(mode: String, theme: QuillTheme) {
        if label.stringValue != mode { label.stringValue = mode }
        let accent = theme.accentColor
        label.textColor = accent
        let fill: CGFloat
        switch mode {
        case "INSERT": fill = 0.18
        case "VISUAL", "V-LINE": fill = 0.16
        case "COMMAND", "SEARCH": fill = 0.14
        default: fill = 0.10
        }
        layer?.backgroundColor = accent.withAlphaComponent(fill).cgColor
        let text = label.intrinsicContentSize
        let width = ceil(text.width) + 14
        label.frame = NSRect(x: 7, y: 3, width: max(1, width - 14), height: 14)
        invalidateIntrinsicContentSize()
    }
}
