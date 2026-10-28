import AppKit
import QuillVim

/// Quiet orientation for an empty buffer. Drawn in the writing column, never
/// as buffer characters. Clicks pass through to the text view.
@MainActor
final class EmptyCanvasView: NSView {
    var theme: QuillTheme? {
        didSet { needsDisplay = true }
    }
    var title: String = "Quill" {
        didSet { if title != oldValue { needsDisplay = true } }
    }
    var untitled: Bool = true {
        didSet { if untitled != oldValue { needsDisplay = true } }
    }
    var leader: String = " " {
        didSet { if leader != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
        setAccessibilityIdentifier("quill.emptyCanvas")
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Empty editor")
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 8, bounds.height > 8, let theme else { return }
        let titleFont = NSFont.systemFont(ofSize: max(18, theme.bodyFont.pointSize * 1.18), weight: .medium)
        let subtitleFont = theme.bodyFont
        let keyFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let actionFont = NSFont.systemFont(ofSize: 11, weight: .regular)
        let titleColor = theme.dimColor
        let bodyColor = theme.dimColor.withAlphaComponent(0.92)
        let keyColor = theme.accentColor.withAlphaComponent(0.88)

        var y: CGFloat = 8
        let rule = NSRect(x: 0, y: y + 4, width: 28, height: 1)
        theme.accentColor.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: rule, xRadius: 0.5, yRadius: 0.5).fill()
        y += 16

        let heading = untitled ? "Quill" : title
        drawLine(heading, font: titleFont, color: titleColor, y: &y, kern: 0.6)
        y += 6
        let subtitle = untitled ? "a quiet place to write" : "empty file"
        drawLine(subtitle, font: subtitleFont, color: bodyColor, y: &y, kern: 0.2)
        y += 18

        for hint in hints {
            let rowY = y
            let keyAttrs: [NSAttributedString.Key: Any] = [
                .font: keyFont,
                .foregroundColor: keyColor,
                .kern: 0.4,
            ]
            let actionAttrs: [NSAttributedString.Key: Any] = [
                .font: actionFont,
                .foregroundColor: bodyColor,
            ]
            (hint.key as NSString).draw(
                with: NSRect(x: 0, y: rowY, width: 108, height: 16),
                options: [.usesLineFragmentOrigin],
                attributes: keyAttrs
            )
            (hint.action as NSString).draw(
                with: NSRect(x: 112, y: rowY, width: max(1, bounds.width - 112), height: 16),
                options: [.usesLineFragmentOrigin],
                attributes: actionAttrs
            )
            y += 18
        }
    }

    private func drawLine(_ text: String, font: NSFont, color: NSColor, y: inout CGFloat, kern: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .kern: kern,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(
            with: NSRect(x: 0, y: y, width: max(size.width, bounds.width), height: size.height + 2),
            options: [.usesLineFragmentOrigin],
            attributes: attrs
        )
        y += size.height + 2
    }

    private var hints: [(key: String, action: String)] {
        let leaderKey = Self.displayLeader(leader)
        return [
            ("i", "start writing"),
            ("\(leaderKey) sf", "find file"),
            ("\(leaderKey) sg", "live grep"),
            ("-", "browse folder"),
            (":e", "open path"),
            ("⌘K", "commands"),
        ]
    }

    static func displayLeader(_ leader: String) -> String {
        if leader == " " || leader.isEmpty { return "Space" }
        if leader == "\t" { return "Tab" }
        return leader
    }
}

extension VimTextView {
    /// True while the empty-canvas overlay is in the tree and unhidden.
    var isEmptyCanvasVisible: Bool {
        emptyCanvas.superview === self && !emptyCanvas.isHidden
    }

    func updateEmptyCanvas() {
        let show = shouldShowEmptyCanvas()
        if show {
            if emptyCanvas.superview !== self {
                addSubview(emptyCanvas, positioned: .below, relativeTo: nil)
            }
            emptyCanvas.theme = theme
            emptyCanvas.title = emptyCanvasTitle
            emptyCanvas.untitled = emptyCanvasUntitled
            emptyCanvas.leader = emptyCanvasLeader
            emptyCanvas.frame = emptyCanvasFrame()
            if emptyCanvas.isHidden { emptyCanvas.isHidden = false }
        } else if !emptyCanvas.isHidden || emptyCanvas.superview != nil {
            emptyCanvas.isHidden = true
            emptyCanvas.removeFromSuperview()
        }
    }

    func shouldShowEmptyCanvas() -> Bool {
        guard engine != nil else { return false }
        guard !isDirectoryBuffer else { return false }
        guard engine.text.isEmpty else { return false }
        switch engine.mode {
        case .normal, .operatorPending, .findChar:
            return true
        default:
            return false
        }
    }

    fileprivate func emptyCanvasFrame() -> NSRect {
        let originY = textContainerInset.height + theme.bodyFont.pointSize * theme.lineHeight * 1.8
        let width = max(160, (textContainer?.size.width ?? 280))
        let height: CGFloat = 220
        return NSRect(
            x: textContainerInset.width,
            y: originY,
            width: width,
            height: height
        )
    }
}
