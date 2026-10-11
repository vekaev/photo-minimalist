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

    var body: some View {
        let items = library.toExport
        VStack(alignment: .leading, spacing: 20) {
            Text("Export leveled photos").font(.title2.weight(.semibold))
            Text("\(items.count) photos marked Level will be rotated and cropped to the largest rectangle with the original aspect ratio. Kept and undecided photos are skipped. Originals are never modified.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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

            if running || finished {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(done), total: Double(max(items.count, 1)))
                    Text(finished ? "Done: \(done - failures.count) exported, \(failures.count) failed" : "Exporting \(done) / \(items.count)")
                        .font(.callout).monospacedDigit()
                    if !failures.isEmpty {
                        ScrollView { Text(failures.joined(separator: "\n")).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(maxHeight: 80)
                    }
                }
            }

            HStack {
                if finished, let d = destinationURL {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([d]) }
                }
                Spacer()
                Button(running ? "Stop" : "Close") {
                    if running { task?.cancel() } else { dismiss() }
                }
                .keyboardShortcut(.cancelAction)
                Button("Export \(items.count) photos") { start(items) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(running || items.isEmpty || destinationURL == nil)
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

    private func start(_ items: [Photo]) {
        guard let dest = destinationURL else { return }
        let jobs = items.map { (id: $0.id, url: $0.url, degrees: $0.correction) }
        let format = format, quality = quality, writeLog = writeLog
        done = 0; failures = []; running = true; finished = false

        task = Task {
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: dest.appendingPathComponent(ImageLoader.exportMarker).path, contents: nil)
            var log = "file,correction_deg,output\n"
            await withTaskGroup(of: (String, Double, String?, String?).self) { group in
                var next = 0
                func add() {
                    let job = jobs[next]; next += 1
                    group.addTask(priority: .userInitiated) {
                        let out = dest.appendingPathComponent(job.id).deletingPathExtension().appendingPathExtension(format.fileExtension)
                        do {
                            try Renderer.export(source: job.url, degrees: job.degrees, to: out, format: format, quality: quality)
                            return (job.id, job.degrees, out.lastPathComponent, nil)
                        } catch {
                            return (job.id, job.degrees, nil, error.localizedDescription)
                        }
                    }
                }
                for _ in 0..<min(4, jobs.count) { add() }
                for await (id, degrees, output, error) in group {
                    done += 1
                    if let error { failures.append("\(id): \(error)") }
                    log += "\"\(id)\",\(String(format: "%.2f", degrees)),\(output.map { "\"\($0)\"" } ?? "")\n"
                    if Task.isCancelled { group.cancelAll(); break }
                    if next < jobs.count { add() }
                }
            }
            if writeLog {
                try? log.write(to: dest.appendingPathComponent("horizon-leveler-log.csv"), atomically: true, encoding: .utf8)
            }
            running = false
            finished = true
        }
    }
}
