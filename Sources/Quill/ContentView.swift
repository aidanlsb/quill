import AppKit
import SwiftUI
import QuillFS
import QuillSearch
import QuillWorkspace

struct ContentView: View {
    @Bindable var model: AppModel

    private var editorBackground: NSColor {
        model.isDirectory ? model.theme.directoryBackgroundColor : model.theme.backgroundColor
    }

    var body: some View {
        ZStack {
            EditorView(model: model, revision: model.revision)
                .background(Color(editorBackground))
            if model.picker != nil {
                PickerPanel(model: model)
            }
            if !model.completions.isEmpty && model.picker == nil {
                VStack {
                    Spacer()
                    HStack {
                        CompletionList(
                            names: model.completions,
                            text: Color(model.theme.textColor),
                            background: Color(model.theme.backgroundColor)
                        ) { model.applyCompletion($0) }
                        Spacer()
                    }
                    .padding(.leading, QuillMetrics.sideGutter)
                    .padding(.bottom, QuillMetrics.verticalInset)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if !model.focusMode {
                StatusBar(model: model)
            }
        }
        .sheet(isPresented: $model.showConfirm) {
            ConfirmSheet(
                ops: model.pendingOps,
                warning: model.confirmWarning,
                onConfirm: model.applyPendingOps,
                onCancel: { model.showConfirm = false }
            )
        }
        .sheet(isPresented: $model.showUnsaved) {
            UnsavedSheet(
                message: model.message,
                onSave: model.saveAndContinue,
                onDiscard: model.discardAndContinue,
                onCancel: model.cancelNavigation
            )
        }
    }
}

struct StatusBar: View {
    var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Text(model.engine.mode.displayName)
            Text(model.title)
            if model.modified {
                Text("•")
            }
            if !model.message.isEmpty {
                Text(model.message)
                    .lineLimit(1)
            }
            Spacer()
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(Color(model.theme.dimColor))
        .padding(.horizontal, model.isDirectory ? QuillMetrics.directoryIconLeading : QuillMetrics.sideGutter)
        .padding(.vertical, 10)
        .background(Color(model.isDirectory ? model.theme.directoryBackgroundColor : model.theme.backgroundColor))
    }
}

struct CompletionList: View {
    var names: [String]
    var text: Color
    var background: Color
    var choose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(names, id: \.self) { name in
                Button(name) { choose(name) }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
        }
        .padding(.vertical, 4)
        .frame(minWidth: 180, alignment: .leading)
        .background(background)
    }
}

struct UnsavedSheet: View {
    var message: String
    var onSave: () -> Void
    var onDiscard: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message.isEmpty ? NavigationGuard.unsavedMessage : message)
                .font(.headline)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Don't Save", action: onDiscard)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct ConfirmSheet: View {
    var ops: [FSOperation]
    var warning: String
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Apply filesystem changes?")
                .font(.headline)
            Text(warning.isEmpty ? "Deletes go to the Trash." : warning)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            List {
                ForEach(Array(ops.enumerated()), id: \.offset) { _, op in
                    Text(op.summary)
                        .font(.system(.body, design: .monospaced))
                }
            }
            .frame(minHeight: 120)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { onConfirm() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 320)
    }
}

struct PickerPanel: View {
    var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let picker = model.picker {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("> " + picker.promptDisplay)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(picker.status)
                }
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color(model.theme.dimColor))
                .padding(.horizontal, QuillMetrics.sideGutter)
                .padding(.top, QuillMetrics.verticalInset)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(picker.items.enumerated()), id: \.offset) { index, item in
                                HStack(alignment: .firstTextBaseline, spacing: 16) {
                                    Text(item.title)
                                        .font(.system(size: 15, design: .monospaced))
                                        .foregroundStyle(Color(model.theme.textColor))
                                    if !item.subtitle.isEmpty {
                                        Text(item.subtitle)
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(Color(model.theme.dimColor))
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 4)
                                .background(
                                    index == picker.selectedIndex
                                        ? Color(model.theme.textColor).opacity(0.08)
                                        : Color.clear
                                )
                                .id(index)
                            }
                        }
                        .padding(.horizontal, QuillMetrics.sideGutter)
                    }
                    .onChange(of: picker.selectedIndex) { _, idx in
                        proxy.scrollTo(idx, anchor: .center)
                    }
                    .id(model.pickerTick)
                }

                if let preview = picker.selected?.preview, !preview.isEmpty {
                    Text(preview)
                        .font(.system(size: 13, design: .monospaced))
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
}

/// Hidden view that receives key events while the picker is open.
struct PickerKeyCatcher: NSViewRepresentable {
    var model: AppModel

    func makeNSView(context: Context) -> PickerKeyView {
        let v = PickerKeyView()
        v.model = model
        Task { @MainActor in
            v.window?.makeFirstResponder(v)
        }
        return v
    }

    func updateNSView(_ nsView: PickerKeyView, context: Context) {
        nsView.model = model
        Task { @MainActor in
            if nsView.window?.firstResponder !== nsView {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }
}

final class PickerKeyView: NSView {
    var model: AppModel?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let model else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
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

