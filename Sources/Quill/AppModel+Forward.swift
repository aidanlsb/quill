import Foundation
import QuillFS
import QuillSearch
import QuillVim

extension AppModel {
    var engine: Engine { document.engine }

    var fileURL: URL? { document.url }

    var isDirectory: Bool { document.isDirectory }

    var directorySnapshot: DirectorySnapshot? { document.snapshot }

    var title: String { document.title }

    var modified: Bool { document.modified }

    var closeRequests: Int { session.closeRequests }

    var diskWrite: @Sendable (Data, URL) async throws -> Void {
        get { document.diskWrite }
        set { document.diskWrite = newValue }
    }

    var picker: PickerEngine? {
        get {
            if case .picker(let opened) = prompt { return opened.picker }
            return nil
        }
        set {
            if newValue == nil { clearPrompt() }
        }
    }

    var pickerKind: PickerKind? {
        get {
            if case .picker(let opened) = prompt { return opened.kind }
            return nil
        }
        set {
            if newValue == nil { clearPrompt() }
        }
    }

    var showConfirm: Bool {
        get {
            if case .confirmFilesystem = prompt { return true }
            return false
        }
        set {
            if !newValue { dismissConfirm() }
        }
    }

    var showUnsaved: Bool {
        get {
            if case .unsaved = prompt { return true }
            return false
        }
        set {
            if !newValue { cancelNavigation() }
        }
    }

    var pendingOps: [FSOperation] {
        if case .confirmFilesystem(let ops, _) = prompt { return ops }
        return []
    }

    var confirmWarning: String {
        if case .confirmFilesystem(_, let warning) = prompt { return warning }
        return ""
    }

    var pendingNavigation: PendingNavigation? {
        if case .unsaved(let navigation) = prompt { return navigation }
        return nil
    }
}
