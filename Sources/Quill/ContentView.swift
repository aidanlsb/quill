import AppKit
import SwiftUI
import QuillFS
import QuillWorkspace

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        ZStack {
            EditorView(model: model, revision: model.revision)
                .background(Color(model.theme.backgroundColor))
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
        .padding(.horizontal, QuillMetrics.sideGutter)
        .padding(.vertical, 10)
        .background(Color(model.theme.backgroundColor))
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

