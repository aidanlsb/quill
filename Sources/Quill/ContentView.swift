import AppKit
import SwiftUI
import QuillFS
import QuillSearch
import QuillWorkspace

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        ZStack {
            EditorView(model: model)
                .background(Color(model.theme.backgroundColor))
            if model.picker != nil {
                PickerPanel(model: model)
            }
            if !model.completions.isEmpty && model.picker == nil {
                VStack {
                    Spacer()
                    HStack {
                        CompletionList(names: model.completions) { model.applyCompletion($0) }
                        Spacer()
                    }
                    .padding(.leading, 48)
                    .padding(.bottom, 56)
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
        .navigationTitle(model.title + (model.modified ? " —" : ""))
    }
}

struct StatusBar: View {
    var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Text(model.engine.mode.displayName)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(modeColor.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(model.title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if model.modified {
                Text("modified")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.orange)
            }
            Spacer()
            if let hover = model.hoverText, !hover.isEmpty {
                Text(hover.replacingOccurrences(of: "\n", with: " · "))
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            Text(model.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("L\(lineNumber)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
    }

    var modeColor: Color {
        switch model.engine.mode {
        case .insert: return .green
        case .visual, .visualLine: return .purple
        default: return .blue
        }
    }

    var lineNumber: Int {
        model.engine.buffer.lineIndex(containing: model.engine.cursor) + 1
    }
}

struct CompletionList: View {
    var names: [String]
    var choose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Wikilinks")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(6)
            ForEach(names, id: \.self) { name in
                Button(name) { choose(name) }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
        }
        .frame(minWidth: 180)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 8)
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
            List(ops.map(\.summary), id: \.self) { line in
                Text(line)
                    .font(.system(.body, design: .monospaced))
            }
            .frame(minHeight: 120)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { onConfirm() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480, height: 320)
    }
}

struct PickerPanel: View {
    var model: AppModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture {
                    model.picker = nil
                    model.pickerKind = nil
                }
            VStack(spacing: 0) {
                if let picker = model.picker {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(picker.mode == .insert ? "INSERT" : "NORMAL")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(picker.mode == .insert ? .green : .blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background((picker.mode == .insert ? Color.green : Color.blue).opacity(0.18))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        Text("> " + picker.promptDisplay)
                            .font(.system(size: 16, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(picker.status)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    Text(picker.mode == .insert
                         ? "Type to filter · Ctrl-n / Ctrl-p · Enter opens · Esc → normal"
                         : "j/k move · gg/G top/bottom · Enter opens · i/a insert · Esc or q closes")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                    Divider()
                    HStack(alignment: .top, spacing: 0) {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(Array(picker.items.enumerated()), id: \.offset) { index, item in
                                        HStack {
                                            Text(item.title)
                                                .font(.system(size: 13, design: .monospaced))
                                            Spacer()
                                            Text(item.subtitle)
                                                .font(.system(size: 11))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 5)
                                        .background(index == picker.selectedIndex ? Color.accentColor.opacity(0.2) : .clear)
                                        .id(index)
                                    }
                                }
                            }
                            .onChange(of: picker.selectedIndex) { _, idx in
                                proxy.scrollTo(idx, anchor: .center)
                            }
                        }
                        Divider()
                        ScrollView {
                            Text(picker.selected?.preview ?? "")
                                .font(.system(size: 12, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .textSelection(.enabled)
                        }
                        .frame(minWidth: 240)
                    }
                    .id(model.pickerTick)
                }
            }
            .frame(minWidth: 640, minHeight: 420)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 24)
            .padding(48)
        }
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

