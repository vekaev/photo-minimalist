import AppKit
import DiskArbitration
import Foundation

/// What to do when a memory card with photos is inserted (Mac only: iOS apps aren't told about cards).
enum CardAction: String, CaseIterable, Identifiable {
    case ask, open, nothing
    var id: String { rawValue }
    static let key = "cardAction"
    /// Open (and bring the window forward) by default; Settings ▸ General can switch it to Ask or Do nothing.
    static var current: CardAction { CardAction(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .open }
    var label: String {
        switch self {
        case .ask: return "Ask"
        case .open: return "Open and show it"
        case .nothing: return "Do nothing"
        }
    }
}

/// The small note at the top right while a card is being read, and after it opened by itself.
enum CardNote: Equatable {
    case reading(String)   // the card's name ("" if macOS doesn't know it yet)
    case opened(String)
    /// "Keep" or "Ask First" was clicked once: the "opened automatically" note doesn't come back.
    static let answeredKey = "cardNoteAnswered"
}

/// A card that was offered in the small banner.
struct CardOffer: Equatable {
    let folder: URL
    let volumeName: String
    let photoCount: Int
}

/// Watches for memory cards. A card counts when it has a DCIM folder with photos in it.
@MainActor
final class CardMonitor {
    /// The frontmost window's library: banners and "Open automatically" go there.
    private var frontmost: () -> Library? = { nil }
    private var library: Library? { frontmost() }
    private var tokens: [NSObjectProtocol] = []

    func start(frontmost: @escaping () -> Library?) {
        guard tokens.isEmpty else { return }
        self.frontmost = frontmost
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] n in
            guard let url = n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            MainActor.assumeIsolated { self?.cardAppeared(url, atLaunch: false) }
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] n in
            guard let url = n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            MainActor.assumeIsolated { self?.cardRemoved(url) }
        })
        watchForDisks()
        // A card that's already in when the app starts.
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsRemovableKey], options: [.skipHiddenVolumes]) ?? []
        for v in volumes where (try? v.resourceValues(forKeys: [.volumeIsRemovableKey]).volumeIsRemovable) == true {
            cardAppeared(v, atLaunch: true)
        }
    }

    /// The folder to open on a card: its only camera folder (e.g. DCIM/100_FUJI), or DCIM if there are several.
    nonisolated static func cameraFolder(on volume: URL) -> URL? {
        let dcim = volume.appendingPathComponent("DCIM", isDirectory: true)
        guard let subs = try? FileManager.default.contentsOfDirectory(at: dcim, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return nil }
        let folders = subs.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        return folders.count == 1 ? folders[0] : (folders.isEmpty ? nil : dcim)
    }

    // MARK: The folder used on each card

    nonisolated private static let foldersKey = "cardFolders"        // volume UUID → folder path inside the card
    nonisolated private static let lastFolderKey = "lastCardFolder"  // the same for whichever card came last

    /// Called whenever a folder opens: on a card, remember it (inside the card, e.g. "DCIM/101_FUJI"), so the
    /// next time this card goes in, that folder opens again. Also kept card-independent, since formatting
    /// a card in the camera gives it a new volume UUID but the same DCIM folders.
    nonisolated static func remember(_ folder: URL) {
        guard let v = try? folder.resourceValues(forKeys: [.volumeURLKey, .volumeIsRemovableKey, .volumeUUIDStringKey]),
              v.volumeIsRemovable == true, let volume = v.volume else { return }
        let base = volume.standardizedFileURL.path, path = folder.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { return }
        let inside = String(path.dropFirst(base.count + 1))
        let d = UserDefaults.standard
        if let id = v.volumeUUIDString {
            var all = d.dictionary(forKey: foldersKey) as? [String: String] ?? [:]
            all[id] = inside
            d.set(all, forKey: foldersKey)
        }
        d.set(inside, forKey: lastFolderKey)
    }

    /// Where to look on a card, best first: the folder used on this card last time, the folder used on any
    /// card last time (if this card has it), then the camera folder.
    nonisolated static func candidates(on volume: URL) -> [URL] {
        let d = UserDefaults.standard
        let id = try? volume.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        let remembered = [id.flatMap { (d.dictionary(forKey: foldersKey) as? [String: String])?[$0] }, d.string(forKey: lastFolderKey)]
        var urls: [URL] = remembered.compactMap { $0 }.map { volume.appendingPathComponent($0, isDirectory: true) }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        if let camera = cameraFolder(on: volume) { urls.append(camera) }
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    // MARK: Inserted / ejected

    /// Has at least one photo: stops at the first one (a card's full listing takes ~0.3–1 s).
    nonisolated static func hasPhotos(_ folder: URL) -> Bool {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return false }
        for case let url as URL in walker where ImageLoader.extensions.contains(url.pathExtension.lowercased()) { return true }
        return false
    }

    private func cardAppeared(_ volume: URL, atLaunch: Bool) {
        let action = CardAction.current
        guard action != .nothing else { return }
        // Inserted now: while the app runs, or the card watcher just launched the app for it (CardWatcher).
        let inserted = !atLaunch || CardWatcher.launchedForCard
        // Opening right away only needs to know there's a photo; the banner shows a count.
        let quick = action == .open && inserted
        let name = volume.lastPathComponent
        Task.detached(priority: .userInitiated) {
            var found: (URL, Int)?
            for folder in Self.candidates(on: volume) {
                if quick {
                    if Self.hasPhotos(folder) { found = (folder, 0); break }
                } else {
                    let count = ImageLoader.pairRawWithJPEG(ImageLoader.listImages(in: folder)).count
                    if count > 0 { found = (folder, count); break }
                }
            }
            let result = found
            await MainActor.run {
                guard let (folder, count) = result else { WindowRouter.shared.cardNotFound(); return }
                let path = folder.standardizedFileURL.path
                let alreadyOpen = WindowRouter.shared.libraries.contains { $0.folder?.standardizedFileURL.path == path }
                // It opens (this tab if it's empty, else a new tab, or its tab if the folder was reopened) and the
                // window comes forward, even from another app or with no window.
                if quick {
                    WindowRouter.shared.openCard(folder, volumeName: name, show: true)
                } else if alreadyOpen {
                    return
                } else if action == .open && self.library?.folder == nil {
                    // A card that was already in at launch fills an empty window, never replaces reopened folders.
                    WindowRouter.shared.openCard(folder, volumeName: name, show: false)
                } else if let library = self.library {
                    library.cardOffer = CardOffer(folder: folder, volumeName: name, photoCount: count)
                }
            }
        }
    }

    // MARK: Detected before it's mounted

    private var session: DASession?

    /// macOS reports a new disk before mounting it, and mounting can take a while (after a card was pulled out
    /// without ejecting, macOS checks it first, which can take many seconds). Come forward as soon as a memory
    /// card is detected, with "Reading memory card…", so it's the first thing on screen; the folder opens on mount.
    private func watchForDisks() {
        guard session == nil, let s = DASessionCreate(kCFAllocatorDefault) else { return }
        session = s
        DASessionScheduleWithRunLoop(s, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(s, nil, { disk, context in
            guard let context, let info = DADiskCopyDescription(disk) as? [CFString: Any] else { return }
            let monitor = Unmanaged<CardMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.diskAppeared(info) }
        }, context)
    }

    private func diskAppeared(_ info: [CFString: Any]) {
        guard CardAction.current == .open,
              info[kDADiskDescriptionVolumePathKey] == nil,                    // not mounted yet (already-present disks are)
              info[kDADiskDescriptionVolumeMountableKey] as? Bool == true,
              info[kDADiskDescriptionMediaRemovableKey] as? Bool == true else { return }
        let proto = info[kDADiskDescriptionDeviceProtocolKey] as? String ?? ""
        let media = info[kDADiskDescriptionMediaNameKey] as? String ?? ""
        // The Mac's SD slot reports "Secure Digital"; USB card readers usually name the media "SD…" or "…Card…".
        guard proto == "Secure Digital" || media.range(of: "SD", options: .caseInsensitive) != nil
                || media.range(of: "card", options: .caseInsensitive) != nil else { return }
        WindowRouter.shared.cardDetected(name: info[kDADiskDescriptionVolumeNameKey] as? String)
    }

    private func cardRemoved(_ volume: URL) {
        CardWatcher.cardRemoved(volume)
        let base = volume.standardizedFileURL.path
        func onCard(_ url: URL?) -> Bool {
            guard let path = url?.standardizedFileURL.path else { return false }
            return path == base || path.hasPrefix(base + "/")   // not "/Volumes/Untitled 1" for "/Volumes/Untitled"
        }
        // The card was what you were looking at: the front window's tab showing it, on screen.
        let front = WindowRouter.shared.frontTabs
        let wasShowing = onCard(front?.current.folder) && front?.window?.isVisible == true && !NSApp.isHidden
        for library in WindowRouter.shared.libraries {
            if library.cardNote != nil { library.cardNote = nil }
            if onCard(library.cardOffer?.folder) { library.cardOffer = nil }
            if onCard(library.folder) {
                // Its tab closes (the last tab stays, showing the start page with this note).
                WindowRouter.shared.close(library, notice: "The card “\(volume.lastPathComponent)” was ejected. Your decisions are saved on it.")
            }
        }
        // It came with the card, it goes with the card: with "Open and show it", taking out the card you were
        // looking at hides the app (decisions are already saved; the Dock icon or ⌘Tab brings it back).
        if wasShowing && CardAction.current == .open {
            NSApp.hide(nil)
        }
    }
}
