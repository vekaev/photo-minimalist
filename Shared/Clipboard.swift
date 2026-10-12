import Foundation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What "Copy" puts on the clipboard.
enum CopyKind {
    /// The photo as you see it: a full-quality leveled JPEG if you leveled it, else the file itself.
    case asShown
    /// The file on disk, untouched by the app's pending decision.
    case original
    /// The RAW twin (e.g. the .RAF).
    case raw
}

extension Library {
    /// Copies photos to the clipboard as files (paste into Finder, Messages, Slack…), plus image data for
    /// apps that only take pictures. Leveled photos are rendered at full quality into a temporary file first.
    func copyPhotos(_ photos: [Photo], kind: CopyKind) {
        let jobs = photos.compactMap { p -> (url: URL, name: String, degrees: Double, crop: CGRect?, band: BandFixSettings?)? in
            switch kind {
            case .raw: return p.rawCompanion.map { ($0, $0.lastPathComponent, 0, nil, nil) }
            case .original: return (p.url, p.name, 0, nil, nil)
            case .asShown: return (p.url, p.name, p.appliedCorrection, p.appliedCrop, p.bandFix)
            }
        }
        guard !jobs.isEmpty else {
            toast = kind == .raw ? "No RAW file next to this photo" : "Nothing selected"
            return
        }
        let needsRender = jobs.contains { abs($0.degrees) >= 0.01 || $0.crop != nil || $0.band != nil }
        if needsRender { toast = jobs.count == 1 ? "Preparing leveled copy…" : "Preparing \(jobs.count) leveled copies…" }
        Task {
            let files: [URL] = await Task.detached(priority: .userInitiated) {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("PhotoMinimalist-Copies/\(UUID().uuidString)", isDirectory: true)
                return jobs.compactMap { job in
                    guard abs(job.degrees) >= 0.01 || job.crop != nil || job.band != nil else { return job.url }
                    let out = dir.appendingPathComponent(job.url.deletingPathExtension().lastPathComponent + ".jpg")
                    return (try? Renderer.export(source: job.url, degrees: job.degrees, crop: job.crop, bandFix: job.band,
                                                 to: out, format: .jpeg, quality: 0.95)) != nil ? out : nil
                }
            }.value
            write(files)
            let noun = kind == .raw ? "RAW file" : "photo"
            toast = files.isEmpty ? "Couldn't copy" : (files.count == 1 ? "Copied \(noun)" : "Copied \(files.count) \(noun)s")
        }
    }

    private func write(_ files: [URL]) {
        #if os(macOS)
        let board = NSPasteboard.general
        board.clearContents()
        let items: [NSPasteboardItem] = files.map { url in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            // Image data too, for apps that paste pictures rather than files (small files only, RAWs as files).
            if !ImageLoader.isRaw(url), let data = try? Data(contentsOf: url), data.count < 60_000_000,
               let type = UTType(filenameExtension: url.pathExtension) {
                item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
            }
            return item
        }
        board.writeObjects(items)
        #else
        UIPasteboard.general.setItemProviders(files.compactMap { NSItemProvider(contentsOf: $0) }, localOnly: false, expirationDate: nil)
        #endif
    }
}
