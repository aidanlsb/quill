import AppKit
import SwiftUI
import QuillSearch

/// Telescope-style picker. The query is an unbezeled field in the text color,
/// with its own caret, so typed characters stay visible while results filter.
struct PickerPanel: View {
    var model: AppModel

    private var opened: PickerSession? {
        if case .picker(let session) = model.prompt { session } else { nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let opened {
                prompt(opened.picker)
                results(opened)
                if let preview = opened.picker.selected?.preview, !preview.isEmpty {
                    Text(preview)
                        .font(.system(size: model.theme.monoFont.pointSize, design: .monospaced))
                        .foregroundStyle(Color(model.theme.dimColor))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, QuillMetrics.sideGutter)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.bottom, QuillMetrics.verticalInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(model.theme.backgroundColor).ignoresSafeArea())
        .background(PickerKeyCatcher(model: model))
    }

    private func prompt(_ picker: PickerEngine) -> some View {
        let theme = model.theme
        let mono = theme.monoFont
        let line = max(16, ceil(mono.ascender - mono.descender + 4))
        let modeFont = NSFontManager.shared.convert(theme.bodyFont, toSize: 12)
        let hintFont = NSFontManager.shared.convert(theme.bodyFont, toSize: mono.pointSize)
        let count = picker.items.count
        let selected = count == 0 ? 0 : picker.selectedIndex + 1
        let caret = caretX(query: picker.query, cursor: picker.queryCursor, font: mono)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                PickerLineField(
                    text: picker.mode == .insert ? "INSERT" : "NORMAL",
                    font: modeFont,
                    color: theme.textColor,
                    identifier: "quill.picker.mode",
                    style: .plain
                )
                .fixedSize(horizontal: true, vertical: true)
                Spacer(minLength: 0)
                Text("\(selected)/\(count)")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(theme.dimColor))
            }
            ZStack(alignment: .leading) {
                PickerLineField(
                    text: picker.query,
                    placeholder: queryPlaceholder,
                    font: mono,
                    color: theme.textColor,
                    placeholderFont: hintFont,
                    placeholderColor: theme.dimColor,
                    identifier: "quill.picker.query",
                    style: .query
                )
                .frame(maxWidth: .infinity, minHeight: line, maxHeight: line, alignment: .leading)
                HStack(spacing: 0) {
                    Color.clear.frame(width: caret, height: 1)
                    if picker.mode == .insert {
                        PickerCaret(color: theme.textColor)
                            .frame(width: 1, height: line * 0.72)
                    }
                    Spacer(minLength: 0)
                }
                .allowsHitTesting(false)
            }
            .frame(height: line)
        }
        .padding(.horizontal, QuillMetrics.sideGutter)
        .padding(.top, QuillMetrics.verticalInset)
    }

    private func results(_ opened: PickerSession) -> some View {
        let picker = opened.picker
        let theme = model.theme
        let style: PickerHighlight.Style = opened.kind == .grep ? .literal : .fuzzy
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(picker.items.enumerated()), id: \.element.payload) { index, item in
                        row(item, index: index, picker: picker, kind: opened.kind, style: style, theme: theme)
                            .id(item.payload)
                    }
                }
                .padding(.horizontal, QuillMetrics.sideGutter)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: picker.selectedIndex) { _, idx in
                guard picker.items.indices.contains(idx) else { return }
                proxy.scrollTo(picker.items[idx].payload, anchor: .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(
        _ item: PickerItem,
        index: Int,
        picker: PickerEngine,
        kind: PickerKind,
        style: PickerHighlight.Style,
        theme: QuillTheme
    ) -> some View {
        let selected = index == picker.selectedIndex
        let commands = kind == .commands
        let titleColor = item.dimmed ? theme.dimColor : theme.textColor
        return HStack(alignment: .firstTextBaseline, spacing: 16) {
            PickerLineField(
                text: item.title,
                attributed: pickerAttributed(
                    item.title,
                    query: picker.query,
                    style: style,
                    font: theme.monoFont,
                    matched: titleColor,
                    unmatched: theme.dimColor
                ),
                font: theme.monoFont,
                color: titleColor,
                identifier: "quill.picker.result",
                style: .rich
            )
            .frame(maxWidth: commands ? .infinity : 560, alignment: .leading)
            if commands {
                if !item.subtitle.isEmpty {
                    PickerLineField(
                        text: item.subtitle,
                        font: NSFontManager.shared.convert(theme.monoFont, toSize: 12),
                        color: theme.dimColor,
                        identifier: "quill.picker.shortcut",
                        style: .plain,
                        alignment: .right
                    )
                    .fixedSize(horizontal: true, vertical: true)
                }
            } else if !item.subtitle.isEmpty {
                PickerLineField(
                    text: item.subtitle,
                    attributed: pickerAttributed(
                        item.subtitle,
                        query: picker.query,
                        style: style,
                        font: theme.monoFont,
                        matched: theme.textColor,
                        unmatched: theme.dimColor
                    ),
                    font: NSFontManager.shared.convert(theme.monoFont, toSize: 12),
                    color: theme.dimColor,
                    identifier: "quill.picker.snippet",
                    style: .rich
                )
                .frame(maxWidth: 320, alignment: .leading)
            }
            if !commands {
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            selected
                ? Color(NSColor.unemphasizedSelectedContentBackgroundColor)
                : Color.clear
        )
    }

    private var queryPlaceholder: String {
        switch opened?.kind {
        case .files: "File name"
        case .grep: "Pattern"
        case .references: "Reference"
        case .codeAction: "Action"
        case .commands: "Command"
        case nil: "Search"
        }
    }

    private func caretX(query: String, cursor: Int, font: NSFont) -> CGFloat {
        let clamped = min(max(0, cursor), query.count)
        let end = query.index(query.startIndex, offsetBy: clamped)
        let before = String(query[..<end])
        if before.isEmpty { return 0 }
        return ceil((before as NSString).size(withAttributes: [.font: font]).width)
    }
}

@MainActor
private func pickerAttributed(
    _ string: String,
    query: String,
    style: PickerHighlight.Style,
    font: NSFont,
    matched: NSColor,
    unmatched: NSColor
) -> NSAttributedString {
    let ranges = PickerHighlight.ranges(query: query, candidate: string, style: style)
    let text = NSMutableAttributedString(string: string)
    let length = text.length
    guard length > 0 else { return text }
    let plain = query.isEmpty || ranges.isEmpty ? matched : unmatched
    text.setAttributes(
        [.font: font, .foregroundColor: plain],
        range: NSRange(location: 0, length: length)
    )
    guard !query.isEmpty, !ranges.isEmpty else { return text }
    let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    for range in ranges {
        guard let ns = utf16Range(range, in: string), NSMaxRange(ns) <= length else { continue }
        text.setAttributes(
            [.font: bold, .foregroundColor: matched],
            range: ns
        )
    }
    return text
}

private func utf16Range(_ range: Range<Int>, in string: String) -> NSRange? {
    guard range.lowerBound >= 0, range.upperBound <= string.count, range.lowerBound < range.upperBound else {
        return nil
    }
    let start = string.index(string.startIndex, offsetBy: range.lowerBound)
    let end = string.index(string.startIndex, offsetBy: range.upperBound)
    let location = string.utf16.distance(from: string.startIndex, to: start)
    let length = string.utf16.distance(from: start, to: end)
    return NSRange(location: location, length: length)
}

private struct PickerLineField: NSViewRepresentable {
    var text: String
    var attributed: NSAttributedString?
    var placeholder: String = ""
    var font: NSFont
    var color: NSColor
    var placeholderFont: NSFont?
    var placeholderColor: NSColor?
    var identifier: String
    var style: Style
    var alignment: NSTextAlignment = .left

    enum Style {
        case query
        case plain
        case rich
    }

    func makeNSView(context: Context) -> PickerReadOnlyField {
        let field = PickerReadOnlyField(string: "")
        switch style {
        case .query:
            field.cell = PickerFlushCell(textCell: "")
        case .rich:
            field.cell = PickerRichCell(textCell: "")
        case .plain:
            break
        }
        apply(field)
        return field
    }

    func updateNSView(_ field: PickerReadOnlyField, context: Context) {
        apply(field)
    }

    private func apply(_ field: NSTextField) {
        field.isEditable = false
        field.isSelectable = false
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.font = font
        field.textColor = color
        field.alignment = alignment
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.cell?.lineBreakMode = .byTruncatingTail
        (field.cell as? NSTextFieldCell)?.drawsBackground = false
        field.cell?.isBordered = false
        field.cell?.isBezeled = false
        field.setAccessibilityIdentifier(identifier)
        if style == .query {
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        } else {
            field.setContentHuggingPriority(.required, for: .horizontal)
        }
        if style == .rich, let attributed {
            field.attributedStringValue = attributed
        } else {
            field.stringValue = text
        }
        if placeholder.isEmpty {
            field.placeholderAttributedString = nil
            field.placeholderString = ""
        } else {
            field.placeholderAttributedString = NSAttributedString(
                string: placeholder,
                attributes: [
                    .font: placeholderFont ?? font,
                    .foregroundColor: placeholderColor ?? color,
                ]
            )
        }
        field.invalidateIntrinsicContentSize()
    }
}

private final class PickerReadOnlyField: NSTextField {
    override var acceptsFirstResponder: Bool { false }
}

/// Query text starts at the field's leading edge so the caret can sit on the same x.
private final class PickerFlushCell: NSTextFieldCell {
    override func titleRect(forBounds rect: NSRect) -> NSRect { rect }
    override func drawingRect(forBounds rect: NSRect) -> NSRect { rect }
}

/// Draws per-range fonts and colors. The default cell paints the whole line in `textColor`.
private final class PickerRichCell: NSTextFieldCell {
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let rect = super.titleRect(forBounds: cellFrame)
        attributedStringValue.draw(with: rect, options: [.usesLineFragmentOrigin], context: nil)
    }
}

private struct PickerCaret: NSViewRepresentable {
    var color: NSColor

    func makeNSView(context: Context) -> PickerCaretView {
        let view = PickerCaretView()
        view.color = color
        view.setAccessibilityIdentifier("quill.picker.caret")
        return view
    }

    func updateNSView(_ view: PickerCaretView, context: Context) {
        view.color = color
        view.setAccessibilityIdentifier("quill.picker.caret")
    }
}

private final class PickerCaretView: NSView {
    var color: NSColor = .labelColor {
        didSet {
            layer?.backgroundColor = color.cgColor
            needsDisplay = true
        }
    }

    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
    }
}

/// Hidden view that receives key events while the picker is open.
struct PickerKeyCatcher: NSViewRepresentable {
    var model: AppModel

    func makeNSView(context: Context) -> PickerKeyView {
        let view = PickerKeyView()
        view.model = model
        return view
    }

    func updateNSView(_ nsView: PickerKeyView, context: Context) {
        nsView.model = model
        nsView.claimFirstResponder()
    }
}

final class PickerKeyView: NSView {
    var model: AppModel?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        claimFirstResponder()
    }

    func claimFirstResponder() {
        guard let window else { return }
        if window.firstResponder !== self {
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let model else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        if flags.contains(.control), let ch = event.charactersIgnoringModifiers?.lowercased().first {
            model.handlePicker(.ctrl(ch))
            return
        }
        switch event.keyCode {
        case 53: model.handlePicker(.escape)
        case 36, 76: model.handlePicker(.enter)
        case 51: model.handlePicker(.backspace)
        case 125: model.handlePicker(.down)
        case 126: model.handlePicker(.up)
        case 123: model.handlePicker(.left)
        case 124: model.handlePicker(.right)
        default:
            if let ch = event.characters?.first {
                model.handlePicker(.character(ch))
            }
        }
    }
}
