import AppKit
import SwiftUI

struct ExportView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    @AppStorage("exportFormat") private var format: ExportFormat = .jpeg
    @AppStorage("exportQuality") private var quality = 0.95
    @AppStorage("exportLog") private var writeLog = true
    @State private var destination: URL?
    @State private var done = 0
    @State private var failures: [String] = []
    @State private var running = false
    @State private var finished = false
    @State private var task: Task<Void, Never>?
    @AppStorage("exportMode") private var replace = false

    var body: some View {
        let items = library.toExport
        VStack(alignment: .leading, spacing: 20) {
            Text(replace ? "Save into originals" : "Export leveled photos").font(.title2.weight(.semibold))
            Picker("", selection: $replace) {
                Text("New copies").tag(false)
                Text("Replace originals").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().disabled(running)
            Text(replace
                 ? "\(library.savable(items.map(\.id)).count) photos will be rotated and cropped in place (JPEG, HEIC, TIFF; RAW files can't be rewritten and stay as shot). The untouched files are kept in a hidden backup folder, so “Restore Original” always works."
                 : "\(items.count) photos marked Level will be rotated and cropped to the largest rectangle with the original aspect ratio, as new files. Kept and undecided photos are skipped. Originals are never modified.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !replace {
            Form {
                Picker("Format", selection: $format) {
                    ForEach(ExportFormat.allCases) { Text($0.label).tag($0) }
                }
                if format != .tiff {
                    LabeledContent("Quality") {
                        HStack {
                            Slider(value: $quality, in: 0.6...1.0, step: 0.01)
                            Text("\(Int(quality * 100))").monospacedDigit().frame(width: 32)
                        }
                    }
                }
                LabeledContent("Save to") {
                    HStack {
                        Text(destinationURL?.path(percentEncoded: false) ?? "—")
                            .lineLimit(1).truncationMode(.head)
                            .font(.system(.callout, design: .monospaced))
                        Button("Change…", action: chooseDestination)
                    }
                }
                Toggle("Write a CSV log of every angle", isOn: $writeLog)
                Text("EXIF, GPS, IPTC and capture date are copied from each original.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .disabled(running)
            }

            if running || finished {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(done), total: Double(max(items.count, 1)))
                    Text(finished ? "Done: \(done - failures.count) \(replace ? "saved" : "exported"), \(failures.count) failed"
                                  : "\(replace ? "Saving" : "Exporting") \(done) / \(items.count)")
                        .font(.callout).monospacedDigit()
                    if !failures.isEmpty {
                        ScrollView { Text(failures.joined(separator: "\n")).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(maxHeight: 80)
                    }
                }
            }

            HStack {
                if finished, !replace, let d = destinationURL {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([d]) }
                }
                PhotosMenu().fixedSize().disabled(running)
                    .help("Adds the original files to Apple Photos (RAW as the alternate); favorites stay favorites")
                Spacer()
                Button(running ? "Stop" : "Close") {
                    if running { task?.cancel() } else { dismiss() }
                }
                .keyboardShortcut(.cancelAction)
                Button(replace ? "Replace \(library.savable(items.map(\.id)).count) originals" : "Export \(items.count) photos") {
                    replace ? startReplace(items) : start(items)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(running || items.isEmpty || (!replace && destinationURL == nil))
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private var destinationURL: URL? {
        destination ?? library.folder?.appendingPathComponent("leveled", isDirectory: true)
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK { destination = panel.url }
    }

    private func startReplace(_ items: [Photo]) {
        let ids = items.map(\.id)
        done = 0; failures = []; running = true; finished = false
        task = Task {
            let result = await library.saveToOriginals(ids) { i, _ in done = i }
            failures = result.failed
            done = result.saved + result.failed.count
            running = false
            finished = true
        }
    }

    private func start(_ items: [Photo]) {
        guard let dest = destinationURL else { return }
        let jobs = items.map { (id: $0.id, url: $0.url, degrees: $0.appliedCorrection, crop: $0.appliedCrop, band: $0.bandFix) }
        let format = format, quality = quality, writeLog = writeLog
        done = 0; failures = []; running = true; finished = false

        task = Task {
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: dest.appendingPathComponent(ImageLoader.exportMarker).path, contents: nil)
            var log = "file,correction_deg,output\n"
            var exported: [String] = []
            await withTaskGroup(of: (String, Double, String?, String?).self) { group in
                var next = 0
                func add() {
                    let job = jobs[next]; next += 1
                    group.addTask(priority: .userInitiated) {
                        let out = dest.appendingPathComponent(job.id).deletingPathExtension().appendingPathExtension(format.fileExtension)
                        do {
                            try Renderer.export(source: job.url, degrees: job.degrees, crop: job.crop, bandFix: job.band,
                                                to: out, format: format, quality: quality)
                            return (job.id, job.degrees, out.lastPathComponent, nil)
                        } catch {
                            return (job.id, job.degrees, nil, error.localizedDescription)
                        }
                    }
                }
                for _ in 0..<min(4, jobs.count) { add() }
                for await (id, degrees, output, error) in group {
                    done += 1
                    if let error { failures.append("\(id): \(error)") } else { exported.append(id) }
                    log += "\"\(id)\",\(String(format: "%.2f", degrees)),\(output.map { "\"\($0)\"" } ?? "")\n"
                    if Task.isCancelled { group.cancelAll(); break }
                    if next < jobs.count { add() }
                }
            }
            if writeLog {
                try? log.write(to: dest.appendingPathComponent("horizon-leveler-log.csv"), atomically: true, encoding: .utf8)
            }
            library.noteExport(exported, to: dest)
            running = false
            finished = true
        }
    }
}
