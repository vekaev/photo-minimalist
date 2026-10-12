import AppKit
import Foundation

/// What to do when a memory card with photos is inserted (Mac only: iOS apps aren't told about cards).
enum CardAction: String, CaseIterable, Identifiable {
    case ask, open, nothing
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ask: return "Ask"
        case .open: return "Open automatically"
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

    private func cardAppeared(_ volume: URL, atLaunch: Bool) {
        guard let library, library.cardAction != .nothing else { return }
        Task.detached(priority: .utility) {
            guard let folder = Self.cameraFolder(on: volume) else { return }
            let count = ImageLoader.pairRawWithJPEG(ImageLoader.listImages(in: folder)).count
            guard count > 0 else { return }
            await MainActor.run {
                guard let library = self.library else { return }
                let path = folder.standardizedFileURL.path
                if WindowRouter.shared.libraries.contains(where: { $0.folder?.standardizedFileURL.path == path }) { return }   // already open in a tab
                let offer = CardOffer(folder: folder, volumeName: volume.lastPathComponent, photoCount: count)
                // At launch, never replace a folder that was reopened; offer instead.
                // Opens in this tab if it's empty, else in a new tab.
                if library.cardAction == .open && (!atLaunch || library.folder == nil) {
                    WindowRouter.shared.open(folder, from: library)
                } else {
                    library.cardOffer = offer
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
