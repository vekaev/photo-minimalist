import SwiftUI

@main
struct HorizonLevelerApp: App {
    /// Each window (tab) has its own Library; the menu commands act on the focused one.
    @FocusedValue(\.library) private var focusedLibrary: Library?
    /// The focused window's tab strip (FolderWindows.swift).
    @FocusedValue(\.folderTabs) private var focusedTabs: FolderTabs?
    private var tabs: FolderTabs? { focusedTabs ?? WindowRouter.shared.frontTabs }
    /// Stands in when no window is focused, so the commands simply do nothing.
    @State private var idle = Library()
    private var library: Library { focusedLibrary ?? idle }

    init() { DispatchQueue.main.async { AppAppearance.current.apply() } }

    /// A text field is being edited: let ⌘C / ⌘V / ⌘A do their usual thing.
    private var editingText: Bool { NSApp.keyWindow?.firstResponder is NSTextView }

    /// What ⌘C and the save commands act on: the open photo (preview / quick look), else the grid selection.
    private var targets: [Photo] {
        library.copyTargets(preferOpened: library.quickLook || UserDefaults.standard.string(forKey: "viewMode") != "grid")
    }

    private func saveTargets() async { await library.saveToOriginalsWithToast(targets.map(\.id)) }

    private func photoKey(_ title: String, _ key: Character, action: @escaping () -> Void) -> some View {
        Button(title) {
            if editingText, let field = NSApp.keyWindow?.firstResponder as? NSTextView { field.insertText(String(key), replacementRange: field.selectedRange()) }
            else { action() }
        }
        .keyboardShortcut(KeyEquivalent(key), modifiers: [])
        .disabled(library.folder == nil)
    }

    var body: some Scene {
        // One window with our own tab strip, one folder per tab (FolderWindows.swift). Restore, the memory
        // card monitor and saving at quit are handled there too.
        WindowGroup("Photo Minimalist", id: "folder") {
            FolderWindow()
                .tint(.primary)
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Tab") { WindowRouter.shared.newTab(from: focusedLibrary) }.keyboardShortcut("t")
                Button("Open Folder…") { WindowRouter.shared.chooseFolders(from: focusedLibrary) }.keyboardShortcut("o")
                Divider()
                // ⌘W closes the tab (saved first); the last tab stays as the start page.
                Button("Close Tab") { if let tabs { tabs.close(tabs.current) } }
                    .keyboardShortcut("w")
                    .disabled(tabs == nil || (tabs!.tabs.count == 1 && tabs!.current.folder == nil))
                Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                Divider()
                Button("Export Leveled Photos…") { library.showExport = true }
                    .keyboardShortcut("e")
                    .disabled(library.toExport.isEmpty)
            }
            // The system Close (⌘W) would close the whole window with all its tabs.
            CommandGroup(replacing: .saveItem) {}
            CommandGroup(before: .windowList) {
                Button("Show Next Tab") { tabs?.cycle(1) }
                    .keyboardShortcut(.tab, modifiers: .control)
                Button("Show Previous Tab") { tabs?.cycle(-1) }
                    .keyboardShortcut(.tab, modifiers: [.control, .shift])
                ForEach(1...9, id: \.self) { n in
                    Button(n == 9 ? "Last Tab" : "Tab \(n)") { tabs?.select(number: n) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                }
                Divider()
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }.keyboardShortcut("x")
                Button("Copy") {
                    if editingText { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
                    else { library.copyPhotos(targets, kind: .asShown) }
                }
                .keyboardShortcut("c")
                Button("Copy Original") { library.copyPhotos(targets, kind: .original) }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                Button("Copy RAW File") { library.copyPhotos(targets, kind: .raw) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Paste") { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }.keyboardShortcut("v")
                Button("Select All") {
                    if editingText { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
                    else { library.selection = Set(library.navigation) }
                }
                .keyboardShortcut("a")
            }
            CommandGroup(after: .pasteboard) {
                Button("Save to Original") { Task { await saveTargets() } }
                    .keyboardShortcut("s")
                Button("Restore Original") { library.restoreOriginals(targets.map(\.id)) }
                Divider()
                // ⌘⌫ like Finder (Delete alone works in the list, grid and preview). ⌘Z puts it back.
                Button("Move to Trash") {
                    if editingText { NSApp.sendAction(#selector(NSText.delete(_:)), to: nil, from: nil) }
                    else { library.requestDelete(targets.map(\.id)) }
                }
                .keyboardShortcut(.delete, modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("History") { library.showActivity = true }
                    .keyboardShortcut("y")
                    .disabled(library.folder == nil)
                Button("Customize Controls…") { library.showControls = true }
                    .disabled(library.folder == nil)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { library.undo() }.keyboardShortcut("z").disabled(!library.canUndo)
                Button("Redo") { library.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!library.canRedo)
            }
            // The single-key shortcuts, visible in a menu. In a text field the key is just typed.
            CommandMenu("Photo") {
                photoKey("Favorite", "f") { library.toggleFavorite(targets.map(\.id)) }
                Divider()
                photoKey("Level", "l") { library.quickLevel(targets.map(\.id)) }
                photoKey("Keep as Shot", "k") { library.decideAndMove(targets.map(\.id), .keep) }
                photoKey("Undecided", "u") { library.decideAndMove(targets.map(\.id), .undecided) }
                Divider()
                photoKey("Level Tool", "r") { library.levelTool.toggle() }
            }
        }

        // ⌘, : app-wide preferences in the standard Settings window (General, Review).
        Settings { PreferencesView() }
    }
}
