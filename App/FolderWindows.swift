import AppKit
import SwiftUI

// One folder per tab, drawn by the app itself in a thin bar at the top of the window (no native
// window tabs: their bar sat over our header and was big and rounded). Each window owns a
// `FolderTabs`; each tab is its own Library. `WindowRouter` knows every window, opens folders
// into tabs and remembers which folders were open.

extension FocusedValues {
    /// The focused window's selected tab: what the menu commands act on.
    @Entry var library: Library?
    /// The focused window's tabs (⌘T, ⌘W, ⌘1…9, ⌃Tab).
    @Entry var folderTabs: FolderTabs?
}

/// The tabs of one window. Each tab has its own Library, exactly like a window used to.
@Observable @MainActor
final class FolderTabs {
    private(set) var tabs: [Library] = [Library()]
    private(set) var selected = 0
    @ObservationIgnored weak var window: NSWindow?
    /// The tab being dragged to a new place.
    @ObservationIgnored weak var dragging: Library?

    var current: Library { tabs[min(selected, tabs.count - 1)] }

    func contains(_ library: Library) -> Bool { tabs.contains { $0 === library } }

    func title(_ library: Library) -> String { library.folder?.lastPathComponent ?? "New Tab" }

    /// A new tab at the end (like Safari), selected; with a folder or the start page.
    @discardableResult
    func newTab(_ folder: URL? = nil, select: Bool = true) -> Library {
        let library = Library()
        tabs.append(library)
        if let folder { library.open(folder) }
        if select { selected = tabs.count - 1 }
        WindowRouter.shared.persist()
        return library
    }

    func select(_ library: Library) {
        if let i = tabs.firstIndex(where: { $0 === library }) { select(index: i) }
    }

    func select(index: Int) {
        guard tabs.indices.contains(index), index != selected else { return }
        selected = index
        WindowRouter.shared.persist()
    }

    /// ⌘1…8 pick that tab, ⌘9 the last one (like Safari).
    func select(number: Int) { select(index: number == 9 ? tabs.count - 1 : number - 1) }

    /// ⌃Tab / ⌃⇧Tab, ⌘⇧] / ⌘⇧[: the next or previous tab, wrapping around.
    func cycle(_ step: Int) {
        guard tabs.count > 1 else { return }
        select(index: (selected + step + tabs.count) % tabs.count)
    }

    /// Saves the tab's decisions and closes it. The last tab stays, showing the start page.
    func close(_ library: Library, notice: String? = nil) {
        guard let i = tabs.firstIndex(where: { $0 === library }) else { return }
        library.closeFolder(notice: notice)   // saves its decisions and stops the background check
        if tabs.count > 1 {
            let wasSelected = current === library
            tabs.remove(at: i)
            if i < selected || selected >= tabs.count { selected = max(0, selected - 1) }
            else if wasSelected { selected = min(i, tabs.count - 1) }
        }
        WindowRouter.shared.persist()
    }

    /// Drag to reorder.
    func move(_ library: Library, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0 === library }), tabs.indices.contains(index), from != index else { return }
        let keep = current
        tabs.move(fromOffsets: [from], toOffset: index > from ? index + 1 : index)
        selected = tabs.firstIndex { $0 === keep } ?? 0
        WindowRouter.shared.persist()
    }

    /// The window closed: save every tab.
    func closeAll() {
        for library in tabs { library.closeFolder() }
    }
}

/// The root of one window: the tab bar above the selected tab's content.
struct FolderWindow: View {
    @State private var tabs = FolderTabs()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let library = tabs.current
        VStack(spacing: 0) {
            TopBar(tabs: tabs)
            ContentView()
                // A fresh view per tab, so per-view state (scroll, focus) never leaks between folders.
                .id(ObjectIdentifier(library))
        }
        .ignoresSafeArea(.container, edges: .top)
        .environment(library)
        .environment(tabs)
        .focusedSceneValue(\.library, library)
        .focusedSceneValue(\.folderTabs, tabs)
        .navigationTitle(library.folder?.lastPathComponent ?? "Photo Minimalist")
        .background(WindowAccessor { window in WindowRouter.shared.attach(window, to: tabs) })
        // F and ⌘⌫ work wherever keyboard focus is in this window (sidebar grid, preview, a clicked control),
        // not only when a particular view happens to hold focus.
        .background(CanvasEvents { e, _ in Self.photoKey(e, library) })
        .onAppear {
            WindowRouter.shared.openWindow = openWindow
            WindowRouter.shared.appeared(tabs)
        }
        .onChange(of: library.folder) { WindowRouter.shared.persist() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            for l in tabs.tabs { syncGlobalSettings(l) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            WindowRouter.shared.terminating()
            for l in tabs.tabs { l.saveNow() }
        }
    }

    /// F = favorite, ⌘⌫ = Move to Trash (asks first, with "Don't ask again", unless that was turned off).
    /// Acts on the open photo, or the grid's selection, like the Photo and Edit menus. A text field keeps its keys.
    static func photoKey(_ e: NSEvent, _ library: Library) -> Bool {
        guard e.type == .keyDown, !e.isARepeat, library.folder != nil, !(e.window?.firstResponder is NSTextView) else { return false }
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let targets = library.copyTargets(preferOpened: library.quickLook || UserDefaults.standard.string(forKey: "viewMode") != "grid").map(\.id)
        guard !targets.isEmpty else { return false }
        if mods.isEmpty, e.charactersIgnoringModifiers?.lowercased() == "f" {
            library.toggleFavorite(targets); return true
        }
        if mods == .command, e.keyCode == 51 || e.keyCode == 117 {     // ⌘⌫ / ⌘⌦
            library.requestDelete(targets); return true
        }
        return false
    }

    /// Settings are app-wide preferences: a change made in one tab shows up in the others.
    private func syncGlobalSettings(_ library: Library) {
        let d = UserDefaults.standard
        if d.bool(forKey: "autoLevel") != library.autoLevel { library.autoLevel = d.bool(forKey: "autoLevel") }
        if let o = ReviewOrder(rawValue: d.string(forKey: "reviewOrder") ?? ""), o != library.reviewOrder { library.reviewOrder = o }
        let advance = d.object(forKey: "advanceAfterDecision") as? Bool ?? false
        if advance != library.advanceAfterDecision { library.advanceAfterDecision = advance }
        let reopen = d.object(forKey: "reopenLastFolder") as? Bool ?? true
        if reopen != library.reopenLastFolder { library.reopenLastFolder = reopen }
        if CardAction.current != library.cardAction { library.cardAction = CardAction.current }
        let pair = d.object(forKey: "pairRaw") as? Bool ?? true
        if pair != library.pairRaw { library.pairRaw = pair }
    }
}

// MARK: Top bar

/// `◨ | [100_FUJI ×] [Iceland] + |  …  checking 12 of 969  ⋯` in the title-bar area, beside the window buttons.
private struct TopBar: View {
    @Environment(Library.self) private var library
    let tabs: FolderTabs
    @AppStorage("showPreview") private var showPreview = true

    nonisolated static let height: CGFloat = 38

    var body: some View {
        HStack(spacing: 0) {
            Button { showPreview.toggle() } label: {
                // Shows where it takes you: home (the full grid / list) while a photo is open beside the list,
                // the sidebar (list + preview) from the full view.
                Image(systemName: showPreview ? "house" : "sidebar.right")
                    .frame(width: 28, height: 26).contentShape(Rectangle())
                    .foregroundStyle(library.folder != nil ? .primary : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .disabled(library.folder == nil)
            .help(showPreview ? "Home: all photos, full window (Space still opens a photo)" : "Show the preview beside the list")
            Theme.line.frame(width: 1, height: 16).padding(.horizontal, 8)
            // Only as wide as the tabs, so the rest of the bar still drags the window; scrolls when crowded.
            ViewThatFits(in: .horizontal) {
                strip
                ScrollView(.horizontal, showsIndicators: false) { strip }
            }
            Spacer(minLength: 12)
            if library.isAnalyzing {
                Text("checking \(library.analyzedCount) of \(library.photos.count)")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    .lineLimit(1).fixedSize()
                    .padding(.trailing, 8)
            }
            MoreMenu()
        }
        .padding(.leading, 78)   // clear of the window buttons
        .padding(.trailing, 10)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        // Empty parts of the bar move the window; a double-click zooms, like a title bar.
        .background(WindowDragArea())
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }

    private var strip: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.tabs.enumerated()), id: \.element.tabID) { i, tab in
                if i > 0 { Theme.line.frame(width: 1, height: 14) }
                TabButton(tabs: tabs, library: tab)
            }
            Button { WindowRouter.shared.chooseFolders(from: tabs.current) } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 26).contentShape(Rectangle())
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.leading, 4)
            .help("Open a folder in a new tab (⌘O). ⌘T opens an empty tab.")
        }
        .fixedSize()
    }
}

/// One square tab: the folder name, × on hover, middle-click closes, drag to reorder.
private struct TabButton: View {
    let tabs: FolderTabs
    let library: Library
    @State private var hovering = false

    var body: some View {
        let isCurrent = tabs.current === library
        HStack(spacing: 4) {
            Text(tabs.title(library))
                .font(.system(size: 12, weight: isCurrent ? .medium : .regular))
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 160, alignment: .leading)
            // Room is kept for the × so the tab doesn't change width on hover.
            Button { tabs.close(library) } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                    .frame(width: 14, height: 14)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 2))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .help("Close tab (⌘W)")
        }
        .foregroundStyle(isCurrent ? .primary : .secondary)
        .padding(.leading, 10).padding(.trailing, 6)
        .frame(height: 26)
        .background(isCurrent ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: 3))
        .contentShape(Rectangle())
        .onTapGesture { tabs.select(library) }
        .overlay(MiddleClick { tabs.close(library) })
        .onHover { hovering = $0 }
        .help(library.folder?.path ?? "Start page")
        .onDrag {
            tabs.dragging = library
            return NSItemProvider(object: (library.folder?.path ?? "") as NSString)
        }
        .onDrop(of: [.text], delegate: TabDrop(tabs: tabs, target: library))
    }
}

/// Reorders while dragging over another tab.
private struct TabDrop: DropDelegate {
    let tabs: FolderTabs
    let target: Library

    func dropEntered(info: DropInfo) {
        guard let dragged = tabs.dragging, dragged !== target, let to = tabs.tabs.firstIndex(where: { $0 === target }) else { return }
        withAnimation(.easeOut(duration: 0.15)) { tabs.move(dragged, to: to) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { tabs.dragging = nil; return true }
}

extension Library {
    /// Identity for the tab strip.
    var tabID: ObjectIdentifier { ObjectIdentifier(self) }
}

/// Catches only the middle mouse button; every other click falls through to the view below.
private struct MiddleClick: NSViewRepresentable {
    let action: () -> Void

    final class Catcher: NSView {
        var action: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let e = NSApp.currentEvent, e.type == .otherMouseDown || e.type == .otherMouseUp else { return nil }
            return super.hitTest(point)
        }
        override func otherMouseUp(with event: NSEvent) {
            if event.buttonNumber == 2 { action?() } else { super.otherMouseUp(with: event) }
        }
    }

    func makeNSView(context: Context) -> Catcher {
        let v = Catcher()
        v.action = action
        return v
    }

    func updateNSView(_ nsView: Catcher, context: Context) { nsView.action = action }
}

/// A title-bar stand-in: drag moves the window, double-click zooms (or minimizes, per System Settings).
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize": window.performMiniaturize(nil)
                case "None": break
                default: window.performZoom(nil)
                }
            } else {
                window.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

/// Hands the hosting NSWindow to SwiftUI code once the view is in a window.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    final class Probe: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let v = Probe()
        v.onWindow = onWindow
        return v
    }

    func updateNSView(_ nsView: Probe, context: Context) {}
}

/// Centers the window buttons in the taller top bar (the system title bar is shorter than ours).
@MainActor
enum TrafficLights {
    static func place(in window: NSWindow, barHeight: CGFloat = TopBar.height) {
        guard !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let titlebar = close.superview, let container = titlebar.superview,
              let contentHeight = container.superview?.frame.height else { return }
        var frame = container.frame
        if frame.height != barHeight || frame.maxY != contentHeight {
            frame.size.height = barHeight
            frame.origin.y = contentHeight - barHeight
            container.frame = frame
            titlebar.frame = container.bounds
        }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let b = window.standardWindowButton(kind) else { continue }
            let y = ((titlebar.frame.height - b.frame.height) / 2).rounded()
            if b.frame.origin.y != y { b.setFrameOrigin(NSPoint(x: b.frame.origin.x, y: y)) }
        }
    }
}

@MainActor
final class WindowRouter {
    static let shared = WindowRouter()

    private final class Weak {
        weak var tabs: FolderTabs?
        init(_ tabs: FolderTabs) { self.tabs = tabs }
    }

    private var windows: [Weak] = []
    private var restored = false
    private var isTerminating = false
    private let cards = CardMonitor()
    private var keyMonitor: Any?
    /// Opens a new window when none is left (kept from the last window that appeared).
    var openWindow: OpenWindowAction?
    /// A card folder waiting for that new window.
    private var pendingCard: (URL, String)?
    /// A card being read while no window was open (its name).
    private var pendingReading: String?

    private init() {
        // Our own tab bar replaces macOS window tabs.
        NSWindow.allowsAutomaticWindowTabbing = false
        // Folders are reopened by `restore`; macOS window restoration would add empty duplicates.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    private var all: [FolderTabs] {
        windows.removeAll { $0.tabs == nil }
        return windows.compactMap(\.tabs)
    }

    // MARK: Windows

    /// A window's root appeared; the first one restores the folders from last time.
    func appeared(_ tabs: FolderTabs) {
        if !all.contains(where: { $0 === tabs }) { windows.append(Weak(tabs)) }
        if !restored {
            restored = true
            // Once: the Overlay compare mode stacked tilted images and confused; start from Off.
            if !UserDefaults.standard.bool(forKey: "compareResetV1") {
                UserDefaults.standard.set("off", forKey: "compareMode")
                UserDefaults.standard.set(true, forKey: "compareResetV1")
            }
            restore(into: tabs)
            cards.start(frontmost: { [weak self] in self?.frontLibrary })
            installKeyMonitor()
        }
        if let (card, name) = pendingCard {
            pendingCard = nil
            pendingReading = nil
            open(card, from: tabs.current)
            if !UserDefaults.standard.bool(forKey: CardNote.answeredKey) { library(showing: card)?.cardNote = .opened(name) }
            // The window is attached a moment after it appears.
            DispatchQueue.main.async { [weak tabs] in Self.bringForward(tabs?.window) }
        } else if let name = pendingReading {
            pendingReading = nil
            tabs.current.cardNote = .reading(name)
            DispatchQueue.main.async { [weak tabs] in Self.bringForward(tabs?.window) }
        }
        persist()
    }

    /// A memory card was detected but isn't mounted yet: come forward now with "Reading memory card…".
    func cardDetected(name: String?) {
        NSApp.unhide(nil)
        guard let library = frontLibrary else {
            pendingReading = name ?? ""
            openWindow?(id: "folder")
            NSApp.activate()
            return
        }
        library.cardNote = .reading(name ?? "")
        Self.bringForward(tabs(of: library)?.window)
    }

    /// The card had no photos (or none could be read): drop "Reading…".
    func cardNotFound() {
        for l in libraries { if case .reading = l.cardNote { l.cardNote = nil } }
    }

    /// A memory card went in (Settings: "Open and show it"): its folder opens in this window's tab if it's
    /// empty, else in a new tab, and the window comes forward, also from another app, when minimized or
    /// when every window was closed. `show: false` (a card that was already in at launch) only opens it.
    func openCard(_ folder: URL, volumeName: String, show: Bool) {
        cardNotFound()
        guard let library = frontLibrary else {
            pendingCard = (folder, volumeName)
            if show { NSApp.unhide(nil); NSApp.activate() }
            // The card watcher's `open` may already be bringing a window back (reopen); only make one if not.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, self.pendingCard != nil, self.frontLibrary == nil else { return }
                self.openWindow?(id: "folder")
            }
            return
        }
        open(folder, from: library)
        guard show else { return }
        // Top right: "Opened “Untitled” automatically · Ask First · Keep", until it's answered once.
        let shown = self.library(showing: folder)
        if !UserDefaults.standard.bool(forKey: CardNote.answeredKey) { shown?.cardNote = .opened(volumeName) }
        NSApp.unhide(nil)
        Self.bringForward(tabs(of: library)?.window)
    }

    /// On screen and in front: un-minimized, ordered front even if macOS doesn't let us take focus
    /// from the app in use (then it still sits on top until that app is clicked).
    private static func bringForward(_ window: NSWindow?) {
        guard let window else { NSApp.activate(); return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.orderFrontRegardless()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func attach(_ window: NSWindow, to tabs: FolderTabs) {
        guard tabs.window !== window else { return }
        tabs.window = window
        window.tabbingMode = .disallowed
        TrafficLights.place(in: window)
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                     NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification] {
            center.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                MainActor.assumeIsolated { if let window { TrafficLights.place(in: window) } }
            }
        }
        // The system lays the title bar out again after a resize; follow it.
        DispatchQueue.main.async { [weak window] in if let window { TrafficLights.place(in: window) } }
        center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self, weak tabs] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isTerminating, let tabs else { return }
                // Remember the folders before they close, so the next launch still has them.
                if self.all.count == 1 { self.save() }
                self.windows.removeAll { $0.tabs == nil || $0.tabs === tabs }
                tabs.closeAll()
                self.persist()
            }
        }
    }

    /// ⌘⇧] / ⌘⇧[ also switch tabs (⌃Tab / ⌃⇧Tab and ⌘1…9 are in the Window menu).
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods == [.command, .shift], event.keyCode == 30 || event.keyCode == 33 else { return event }
            let step = event.keyCode == 30 ? 1 : -1
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let tabs = self?.frontTabs else { return false }
                tabs.cycle(step)
                return true
            }
            return handled ? nil : event
        }
    }

    /// ⌘T: a new tab with the start page.
    func newTab(from library: Library?) {
        (tabs(of: library) ?? frontTabs)?.newTab()
    }

    /// Opens folders: the first in `library`'s tab if it's empty, the rest in new tabs.
    /// A folder that's already open just brings its tab forward.
    func open(_ urls: [URL], from library: Library?) {
        guard let tabs = tabs(of: library) ?? frontTabs else { return }
        var target = (library?.folder == nil) ? library : nil
        for url in urls {
            if let existing = self.library(showing: url) {
                select(existing)
                continue
            }
            if let t = target {
                t.open(url)
                tabs.select(t)
                target = nil
            } else {
                tabs.newTab(url)
            }
        }
        persist()
    }

    func open(_ url: URL, from library: Library?) { open([url], from: library) }

    /// ⌘O and "+": pick one or more folders.
    func chooseFolders(from library: Library?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Open"
        panel.message = "Choose folders of photos. Each opens in its own tab; subfolders are included."
        if panel.runModal() == .OK { open(panel.urls, from: library) }
    }

    /// Closes the tab showing `library` (the memory card was ejected, ⌘W).
    func close(_ library: Library, notice: String? = nil) {
        if let tabs = tabs(of: library) { tabs.close(library, notice: notice) } else { library.closeFolder(notice: notice) }
    }

    // MARK: Lookup

    var frontTabs: FolderTabs? {
        let key = NSApp.keyWindow ?? NSApp.mainWindow
        return all.first { $0.window === key && key != nil } ?? all.first
    }

    var frontLibrary: Library? { frontTabs?.current }

    var libraries: [Library] { all.flatMap(\.tabs) }

    func tabs(of library: Library?) -> FolderTabs? {
        guard let library else { return nil }
        return all.first { $0.contains(library) }
    }

    private func library(showing url: URL) -> Library? {
        let path = url.standardizedFileURL.path
        return libraries.first { $0.folder?.standardizedFileURL.path == path }
    }

    private func select(_ library: Library) {
        guard let tabs = tabs(of: library) else { return }
        tabs.select(library)
        tabs.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Remembering open folders

    /// Saves the open folders in tab order ("openFolders") and the active one ("activeFolder", also "lastFolder").
    func persist() {
        guard restored, !isTerminating else { return }
        save()
    }

    func terminating() {
        guard !isTerminating else { return }
        save()
        isTerminating = true
    }

    private func save() {
        guard !all.isEmpty else { return }   // the last window is closing: keep what was saved
        // The front window's tabs first, then any other windows.
        var ordered = all
        if let front = frontTabs, let i = ordered.firstIndex(where: { $0 === front }) {
            ordered.insert(ordered.remove(at: i), at: 0)
        }
        var paths: [String] = []
        for tabs in ordered {
            for l in tabs.tabs {
                if let p = l.folder?.path, !paths.contains(p) { paths.append(p) }
            }
        }
        let d = UserDefaults.standard
        d.set(paths, forKey: "openFolders")
        if let active = frontTabs?.current.folder?.path {
            d.set(active, forKey: "activeFolder")
            d.set(active, forKey: "lastFolder")
        }
    }

    /// At launch: every folder that was open, each in its own tab of this window, the active one selected.
    /// Folders that are gone (an ejected card) are skipped silently.
    private func restore(into tabs: FolderTabs) {
        let library = tabs.current
        let d = UserDefaults.standard
        let explicit = d.string(forKey: "openFolder") != nil   // `-openFolder <path>` for testing
        let reopen = d.object(forKey: "reopenLastFolder") as? Bool ?? true
        let paths = (d.stringArray(forKey: "openFolders") ?? []).filter { FileManager.default.fileExists(atPath: $0) }
        guard !explicit, reopen, !paths.isEmpty else {
            library.restoreLastFolder()
            return
        }
        let active = d.string(forKey: "activeFolder")
        library.open(URL(fileURLWithPath: paths[0]))
        for p in paths.dropFirst() {
            tabs.newTab(URL(fileURLWithPath: p), select: false)
        }
        if let active, let i = paths.firstIndex(of: active) { tabs.select(index: i) }
    }
}
