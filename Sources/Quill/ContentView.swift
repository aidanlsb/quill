import AppKit
import SwiftUI
import QuillFS
import QuillWorkspace

struct ContentView: View {
    @Bindable var model: AppModel

    private var editorBackground: NSColor {
        model.document.isDirectory ? model.theme.directoryBackgroundColor : model.theme.backgroundColor
    }

    var body: some View {
        ZStack {
            EditorView(model: model, diagnostics: model.diagnosticRanges, refresh: model.document.refreshID)
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
                            selection: model.completionIndex,
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
        .sheet(isPresented: Binding(
            get: { if case .confirmFilesystem = model.prompt { true } else { false } },
            set: { presented in
                if !presented, case .confirmFilesystem = model.prompt { model.dismissConfirm() }
            }
        )) {
            ConfirmSheet(
                ops: model.pendingOps,
                warning: model.confirmWarning,
                onConfirm: model.applyPendingOps,
                onCancel: model.dismissConfirm
            )
        }
        .sheet(isPresented: Binding(
            get: { if case .unsaved = model.prompt { true } else { false } },
            set: { presented in
                if !presented, case .unsaved = model.prompt { model.cancelNavigation() }
            }
        )) {
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
            Text(model.document.engine.mode.displayName)
            Text(model.document.title)
            if model.document.modified {
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
        .padding(.horizontal, model.document.isDirectory ? QuillMetrics.directoryIconLeading : QuillMetrics.sideGutter)
        .padding(.vertical, 10)
        .background(Color(model.document.isDirectory ? model.theme.directoryBackgroundColor : model.theme.backgroundColor))
    }
}

struct CompletionList: View {
    var names: [String]
    var selection: Int
    var text: Color
    var background: Color
    var choose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                Button(name) { choose(name) }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(index == selection ? text.opacity(0.16) : Color.clear)
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
                    .keyboardShortcut(.cancelAction)
                Button("Don't Save", action: onDiscard)
                    .keyboardShortcut("d", modifiers: .command)
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

