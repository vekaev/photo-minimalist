import AppKit
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

    private func cardAppeared(_ volume: URL, atLaunch: Bool) {
        let action = CardAction.current
        guard action != .nothing else { return }
        Task.detached(priority: .utility) {
            // The first candidate that has photos in it.
            var found: (URL, Int)?
            for folder in Self.candidates(on: volume) {
                let count = ImageLoader.pairRawWithJPEG(ImageLoader.listImages(in: folder)).count
                if count > 0 { found = (folder, count); break }
            }
            guard let (folder, count) = found else { return }
            await MainActor.run {
                let path = folder.standardizedFileURL.path
                if WindowRouter.shared.libraries.contains(where: { $0.folder?.standardizedFileURL.path == path }) { return }   // already open in a tab
                // Inserted while the app runs: open it (this tab if it's empty, else a new tab) and bring the
                // window forward, even from another app or with no window open.
                // At launch, never replace a folder that was reopened; offer instead.
                if action == .open && (!atLaunch || self.library?.folder == nil) {
                    WindowRouter.shared.openCard(folder, show: !atLaunch)
                } else if let library = self.library {
                    library.cardOffer = CardOffer(folder: folder, volumeName: volume.lastPathComponent, photoCount: count)
                }
            }
        }
    }

    private func cardRemoved(_ volume: URL) {
        for library in WindowRouter.shared.libraries {
            if library.cardOffer?.folder.path.hasPrefix(volume.path) == true { library.cardOffer = nil }
            if let folder = library.folder, folder.standardizedFileURL.path.hasPrefix(volume.standardizedFileURL.path) {
                // Its tab closes (the last tab stays, showing the start page with this note).
                WindowRouter.shared.close(library, notice: "The card “\(volume.lastPathComponent)” was ejected. Your decisions are saved on it.")
            }
        }
    }
}
