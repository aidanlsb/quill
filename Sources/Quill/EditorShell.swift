import AppKit
import SwiftUI

/// The document window. AppKit owns the text view and the status line so the first frame does not wait on a SwiftUI scene.
@MainActor
final class EditorShell: NSViewController, VimTextViewDelegate {
    let model: AppModel
    let textView: VimTextView
    private let scroll: NSScrollView
    private let statusBar = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var pickerHost: NSHostingController<PickerPanel>?
    private var completionHost: NSHostingController<CompletionList>?
    private var sheetController: NSViewController?
    private var sheetKind: SheetKind?
    private var wasBlocking = false
    private var didDisplay = false

    private enum SheetKind: Equatable {
        case unsaved
        case confirm
    }

    init(model: AppModel) {
        self.model = model
        let hosted = VimTextView.host(
            engine: model.engine,
            frame: NSRect(x: 0, y: 0, width: 960, height: 760),
            theme: model.theme
        )
        scroll = hosted.scroll
        textView = hosted.view
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 760))
        view = root
        scroll.frame = root.bounds
        scroll.autoresizingMask = [.width, .height]
        root.addSubview(scroll)
        statusBar.wantsLayer = true
        statusBar.frame = NSRect(x: 0, y: 0, width: 960, height: 28)
        statusLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.frame = NSRect(x: 16, y: 5, width: 900, height: 18)
        statusBar.addSubview(statusLabel)
        root.addSubview(statusBar)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutChrome()
    }

    /// Styles the buffer that is already loaded. Called once, before the window is ordered front.
    func displayDocument() {
        guard !didDisplay else { return }
        didDisplay = true
        StartupProbe.markOnce("editorRoot")
        textView.vimDelegate = self
        model.editor = textView
        view.layoutSubtreeIfNeeded()
        sync()
        if textView.string != model.engine.text {
            textView.reload()
        }
        model.onInterfaceChange = { [weak self] in
            self?.sync()
        }
    }

    func vimTextView(_ view: VimTextView, didHandle result: EngineResult) {
        model.afterEdit(result)
    }

    func vimTextViewDidClick(_ view: VimTextView, characterOffset: Int, commandClick: Bool) {
        if commandClick {
            model.goToDefinition()
        }
    }

    func vimTextView(_ view: VimTextView, handleCompletionKey key: KeyEvent) -> Bool {
        model.handleCompletionKey(key)
    }

    private func sync() {
        let tv = textView
        tv.engine = model.engine
        if model.editor == nil || tv.window?.isKeyWindow == true {
            model.editor = tv
        }
        tv.columnWidth = model.theme.columnWidth
        tv.setImageContext(
            enabled: model.showImages,
            filePath: model.document.isDirectory ? nil : model.document.url?.path
        )
        let entries = model.document.isDirectory ? (model.document.snapshot?.entries ?? []) : []
        let url = model.document.isDirectory ? model.document.url : nil
        let directoryChanged = tv.isDirectoryBuffer != model.document.isDirectory
            || tv.directoryURL != url
            || tv.directoryEntries != entries
        tv.isDirectoryBuffer = model.document.isDirectory
        tv.directoryURL = url
        tv.directoryEntries = entries
        if directoryChanged { tv.invalidateDirectoryStyle() }
        let diagnostics = model.diagnosticRanges
        let diagnosticsChanged = tv.diagnosticRanges.count != diagnostics.count
            || tv.diagnosticRanges.map(\.0) != diagnostics.map(\.0)
        if diagnosticsChanged {
            tv.diagnosticRanges = diagnostics
            tv.queueRestyle()
        }
        if model.document.isDirectory {
            scroll.drawsBackground = true
            scroll.backgroundColor = model.theme.directoryBackgroundColor
            tv.window?.backgroundColor = model.theme.directoryBackgroundColor
        } else {
            scroll.drawsBackground = false
        }
        if !syncWindowChrome(
            view: tv,
            theme: model.theme,
            themeIdentity: model.themeIdentity,
            focus: model.focusMode,
            directoryChanged: directoryChanged
        ) {
            tv.updateInsets()
        }
        updateStatus()
        syncPicker()
        syncCompletions()
        syncSheets()
        let blocking = pickerHost != nil || sheetController != nil
        if !blocking, tv.window?.firstResponder !== tv {
            tv.window?.makeFirstResponder(tv)
        }
        if wasBlocking, !blocking {
            tv.window?.makeFirstResponder(tv)
        }
        wasBlocking = blocking
        tv.syncFromEngine(isEditor: model.editor === tv, refresh: model.document.refreshID)
        layoutChrome()
    }

    private func updateStatus() {
        let directory = model.document.isDirectory
        let background = directory ? model.theme.directoryBackgroundColor : model.theme.backgroundColor
        statusBar.layer?.backgroundColor = background.cgColor
        var parts = [model.status, model.document.title]
        if model.document.modified { parts.append("•") }
        if !model.message.isEmpty { parts.append(model.message) }
        let line = parts.joined(separator: "  ")
        if statusLabel.stringValue != line { statusLabel.stringValue = line }
        statusLabel.textColor = model.theme.dimColor
        view.window?.title = model.document.title
    }

    private func syncPicker() {
        guard case .picker = model.prompt else {
            removePicker()
            return
        }
        if pickerHost == nil {
            let host = NSHostingController(rootView: PickerPanel(model: model))
            host.view.translatesAutoresizingMaskIntoConstraints = true
            pickerHost = host
            view.addSubview(host.view, positioned: .below, relativeTo: statusBar)
        }
    }

    private func removePicker() {
        pickerHost?.view.removeFromSuperview()
        pickerHost = nil
    }

    private func syncCompletions() {
        let names = model.completions
        let show = pickerHost == nil && sheetController == nil && !names.isEmpty
        guard show else {
            removeCompletions()
            return
        }
        let list = CompletionList(
            names: names,
            selection: model.completionIndex,
            text: Color(model.theme.textColor),
            background: Color(model.theme.backgroundColor)
        ) { [weak model] name in
            model?.applyCompletion(name)
        }
        if let completionHost {
            completionHost.rootView = list
        } else {
            let host = NSHostingController(rootView: list)
            host.view.translatesAutoresizingMaskIntoConstraints = true
            completionHost = host
            view.addSubview(host.view, positioned: .above, relativeTo: scroll)
        }
    }

    private func removeCompletions() {
        completionHost?.view.removeFromSuperview()
        completionHost = nil
    }

    private func syncSheets() {
        let next: SheetKind?
        switch model.prompt {
        case .unsaved: next = .unsaved
        case .confirmFilesystem: next = .confirm
        default: next = nil
        }
        if next == sheetKind { return }
        if let sheetController {
            dismiss(sheetController)
            self.sheetController = nil
            sheetKind = nil
        }
        guard let next else { return }
        let host: NSViewController
        switch model.prompt {
        case .unsaved:
            let sheet = NSHostingController(rootView: UnsavedSheet(
                message: model.message,
                onSave: { [weak model] in model?.saveAndContinue() },
                onDiscard: { [weak model] in model?.discardAndContinue() },
                onCancel: { [weak model] in model?.cancelNavigation() }
            ))
            sheet.preferredContentSize = NSSize(width: 420, height: 150)
            host = sheet
        case .confirmFilesystem(let ops, let warning):
            let sheet = NSHostingController(rootView: ConfirmSheet(
                ops: ops,
                warning: warning,
                onConfirm: { [weak model] in model?.applyPendingOps() },
                onCancel: { [weak model] in model?.dismissConfirm() }
            ))
            sheet.preferredContentSize = NSSize(width: 480, height: 320)
            host = sheet
        default:
            return
        }
        sheetKind = next
        sheetController = host
        presentAsSheet(host)
    }

    private func layoutChrome() {
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }
        let hideStatus = model.focusMode
        statusBar.isHidden = hideStatus
        let statusHeight: CGFloat = hideStatus ? 0 : 28
        let statusFrame = NSRect(x: 0, y: 0, width: bounds.width, height: 28)
        let scrollFrame = NSRect(
            x: 0,
            y: statusHeight,
            width: bounds.width,
            height: max(1, bounds.height - statusHeight)
        )
        if statusBar.frame != statusFrame { statusBar.frame = statusFrame }
        if scroll.frame != scrollFrame { scroll.frame = scrollFrame }
        let leading = model.document.isDirectory ? QuillMetrics.directoryIconLeading : QuillMetrics.sideGutter
        let labelWidth = max(1, bounds.width - leading - 12)
        let labelFrame = NSRect(x: leading, y: 5, width: labelWidth, height: 18)
        if statusLabel.frame != labelFrame { statusLabel.frame = labelFrame }
        if let picker = pickerHost?.view, picker.frame != scrollFrame {
            picker.frame = scrollFrame
        }
        if let completion = completionHost?.view {
            let width = min(420, max(180, scrollFrame.width - leading - 24))
            let rows = CGFloat(max(model.completions.count, 1))
            let height = min(max(1, scrollFrame.height * 0.45), rows * 22 + 8)
            let frame = NSRect(
                x: scrollFrame.minX + min(leading, max(0, scrollFrame.width - width)),
                y: scrollFrame.minY + 12,
                width: width,
                height: height
            )
            if completion.frame != frame { completion.frame = frame }
        }
    }
}
