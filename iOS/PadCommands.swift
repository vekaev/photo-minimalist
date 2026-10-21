import SwiftUI
import UIKit

// Hardware keyboard (iPad with a keyboard; harmless elsewhere). Menu commands, so holding ⌘ / the iPadOS menu bar
// lists them. They act on the focused window's Library (`padLibrary`) and its editor (`editorKeys`).

extension FocusedValues {
    @Entry var padLibrary: Library?
    @Entry var editorKeys: EditorKeys?
    @Entry var openFolder: Binding<Bool>?
}

/// What the editor offers the keyboard: its view-local modes (original, crop, level tool, two-point pick).
struct EditorKeys {
    var showOriginal = false
    var cropMode = false
    var levelMode = false
    var adjustMode = false
    var pickActive = false
    /// The photo is zoomed in (Fit is available).
    var zoomed = false
    /// ⌘+ / ⌘− / ⌘0.
    var zoom: (ZoomCommand) -> Void = { _ in }
    var toggleOriginal: () -> Void = {}
    var toggleInfo: () -> Void = {}
    var toggleLevelTool: () -> Void = {}
    var toggleCrop: () -> Void = {}
    var toggleAdjust: () -> Void = {}
    /// ↵: crop Done, "Level along this line", level tool / Adjust Done.
    var confirm: () -> Void = {}
    /// Esc: leave crop, clear a pick, close the level tool.
    var cancel: () -> Void = {}

    var canConfirm: Bool { cropMode || levelMode || adjustMode }
}

struct PadCommands: Commands {
    @FocusedValue(\.padLibrary) private var library
    @FocusedValue(\.editorKeys) private var editor
    @FocusedValue(\.openFolder) private var openFolder

    /// A sheet or popover with its own fields is up: keys belong to it.
    private var busy: Bool {
        guard let library else { return true }
        return library.showActivity || library.showSettings || library.pendingDelete != nil
    }
    private var photo: Photo? { busy ? nil : library?.photo(library?.openedID) }
    /// The History sheet (with its search field) is up.
    private var textUndo: Bool { library?.showActivity ?? false }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Folder…") { openFolder?.wrappedValue = true }
                .keyboardShortcut("o")
                .disabled(openFolder == nil)
        }
        // Says what it will undo ("Undo Level DSCF0015"). A text field being edited (History search) keeps its own
        // undo: while the History sheet is up the items stay enabled for it.
        CommandGroup(replacing: .undoRedo) {
            Button(busy ? "Undo" : library?.undoTitle ?? "Undo") {
                if TextResponder.isEditing { TextResponder.current?.undoManager?.undo() } else if !busy { library?.undo() }
            }
            .keyboardShortcut("z")
            .disabled(!textUndo && (busy || !(library?.canUndo ?? false)))
            Button(busy ? "Redo" : library?.redoTitle ?? "Redo") {
                if TextResponder.isEditing { TextResponder.current?.undoManager?.redo() } else if !busy { library?.redo() }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!textUndo && (busy || !(library?.canRedo ?? false)))
        }
        // ⌘C copies the photo as shown; in a text field the standard edit actions still go to the field.
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { TextResponder.send(#selector(UIResponderStandardEditActions.cut(_:))) }
                .keyboardShortcut("x")
            Button(photo == nil ? "Copy" : "Copy Photo") {
                if TextResponder.isEditing || photo == nil {
                    TextResponder.send(#selector(UIResponderStandardEditActions.copy(_:)))
                } else if let photo, let library {
                    library.copyPhotos([photo], kind: .asShown)
                }
            }
            .keyboardShortcut("c")
            Button("Paste") { TextResponder.send(#selector(UIResponderStandardEditActions.paste(_:))) }
                .keyboardShortcut("v")
            Button("Select All") { TextResponder.send(#selector(UIResponderStandardEditActions.selectAll(_:))) }
                .keyboardShortcut("a")
        }
        CommandMenu("Photo") {
            let p = photo
            let crop = editor?.cropMode ?? false
            Button("Previous Photo") { step(-1) }.keyboardShortcut(.leftArrow, modifiers: []).disabled(p == nil || crop)
            Button("Next Photo") { step(1) }.keyboardShortcut(.rightArrow, modifiers: []).disabled(p == nil || crop)
            Button("Photo Above") { step(-row) }.keyboardShortcut(.upArrow, modifiers: []).disabled(p == nil || crop)
            Button("Photo Below") { step(row) }.keyboardShortcut(.downArrow, modifiers: []).disabled(p == nil || crop)
            Divider()
            Button(editor?.showOriginal == true ? "Show Result" : "Show Original") { editor?.toggleOriginal() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(p == nil || editor == nil)
            Button("Info") { editor?.toggleInfo() }
                .keyboardShortcut("i", modifiers: [])
                .disabled(p == nil || editor == nil)
            Divider()
            Button("Level") { if let p { library?.levelAndAdjust([p.id]) } }
                .keyboardShortcut("l", modifiers: []).disabled(p == nil)
            Button("Keep as Shot") { if let p { library?.decideAndMove([p.id], .keep) } }
                .keyboardShortcut("k", modifiers: []).disabled(p == nil)
            Button("Undecided") { if let p { library?.decideAndMove([p.id], .undecided) } }
                .keyboardShortcut("u", modifiers: []).disabled(p == nil)
            Button(p?.favorite == true ? "Unfavorite" : "Favorite") { if let p { library?.toggleFavorite([p.id]) } }
                .keyboardShortcut("f", modifiers: []).disabled(p == nil)
            Divider()
            // Zoom (also pinch, two fingers to pan, double-tap fit ⇄ 2×).
            Button("Zoom In") { editor?.zoom(.zoomIn) }
                .keyboardShortcut("+").disabled(p == nil || editor == nil)
            Button("Zoom Out") { editor?.zoom(.zoomOut) }
                .keyboardShortcut("-").disabled(p == nil || editor == nil || !(editor?.zoomed ?? false))
            Button("Fit") { editor?.zoom(.fit) }
                .keyboardShortcut("0").disabled(p == nil || editor == nil || !(editor?.zoomed ?? false))
            Divider()
            Button(editor?.levelMode == true ? "Close Level Tool" : "Level Tool") { editor?.toggleLevelTool() }
                .keyboardShortcut("r", modifiers: []).disabled(p == nil || editor == nil)
            Button(crop ? "Close Crop" : "Crop") { editor?.toggleCrop() }
                .keyboardShortcut("c", modifiers: []).disabled(p == nil || editor == nil)
            Button(editor?.adjustMode == true ? "Close Adjust" : "Adjust") { editor?.toggleAdjust() }
                .keyboardShortcut("e", modifiers: []).disabled(p == nil || editor == nil)
            Button("Auto Light") { if let p { library?.autoLight([p.id]) } }.disabled(p == nil)
            Button("Done") { editor?.confirm() }
                .keyboardShortcut(.return, modifiers: []).disabled(p == nil || !(editor?.canConfirm ?? false))
            Button("Cancel") { editor?.cancel() }
                .keyboardShortcut(.escape, modifiers: []).disabled(p == nil || !(editor?.canConfirm ?? false))
            Divider()
            Button("Move to Trash…") { if let p { library?.requestDelete([p.id]) } }
                .keyboardShortcut(.delete, modifiers: .command).disabled(p == nil)
        }
    }

    /// ↑↓ move by a row in the grid, by one in the list.
    private var row: Int { library.map { $0.gridActive ? max($0.gridColumns, 1) : 1 } ?? 1 }

    private func step(_ delta: Int) {
        guard let library else { return }
        withAnimation(.easeOut(duration: 0.15)) { library.step(delta) }
    }
}

/// The first responder, to leave the standard edit keys to a text field that has focus.
@MainActor
enum TextResponder {
    fileprivate static weak var found: UIResponder?

    static var current: UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.hl_captureFirstResponder(_:)), to: nil, from: nil, for: nil)
        return found
    }

    static var isEditing: Bool { current is UITextInput }

    static func send(_ action: Selector) { UIApplication.shared.sendAction(action, to: nil, from: nil, for: nil) }
}

extension UIResponder {
    @objc fileprivate func hl_captureFirstResponder(_ sender: Any?) { TextResponder.found = self }
}
