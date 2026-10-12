import SwiftUI

/// iPhone counterpart of the Mac's Fixes panel: a bottom sheet over the editor with the per-side status, the
/// strengths, flatten, Before / After, Reset and Remove. The editor behind shows `draft` live; a control stores it
/// when released (one undoable step). Zones, tilt and rows stay on the Mac. Hidden unless Settings ▸ Advanced is on.
struct FixesSheet: View {
    @Environment(Library.self) private var library
    let photo: Photo
    @Binding var draft: BandFixSettings
    @Binding var showBefore: Bool

    @State private var analysis: BandAnalysis?
    @State private var measuring = false

    private var applied: Bool { photo.bandFix != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    BandStatusLines(analysis: analysis, loading: measuring)
                    Picker("View", selection: $showBefore) {
                        Text("Before").tag(true)
                        Text("After").tag(false)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Shutter bands")
                } footer: {
                    Text(applied ? "Applied. Changes are stored when you let go; Undo goes back."
                                 : "Preview only. Adjust or tap Apply to keep it.")
                }
                Section {
                    slider("Left strength", \.left, 0...2) { String(format: "%.0f%%", $0 * 100) }
                    slider("Right strength", \.right, 0...2) { String(format: "%.0f%%", $0 * 100) }
                    slider("Flatten edge", \.flatten, 0...1) { String(format: "%.2f", $0) }
                    Toggle("Correct even if not detected", isOn: Binding(get: { draft.force }, set: { draft.force = $0; commit() }))
                }
                Section("Brightness across the frame") {
                    BandProfileChart(analysis: analysis).padding(.vertical, 6)
                }
                Section {
                    Button("Reset") {
                        draft = BandFixSettings()
                        if applied { commit() }
                    }
                    if applied {
                        Button("Remove Fix", role: .destructive) { library.removeBandFix([photo.id]) }
                    } else {
                        Button("Apply Fix") { commit() }
                    }
                }
            }
            .navigationTitle("Fixes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { library.fixesTool = false } }
            }
        }
        .tint(.primary)
        .task(id: photo.url.path + "|" + BandFixStore.settingsKey(draft)) {
            measuring = true
            let a = await BandFixStore.shared.analysis(url: photo.url, settings: draft)
            guard !Task.isCancelled else { return }
            analysis = a
            measuring = false
        }
    }

    private func commit() { library.setBandFix(photo.id, draft) }

    private func slider(_ title: String, _ key: WritableKeyPath<BandFixSettings, Double>, _ range: ClosedRange<Double>,
                        format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(draft[keyPath: key])).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: Binding(get: { draft[keyPath: key] }, set: { draft[keyPath: key] = ($0 * 100).rounded() / 100 }),
                   in: range) { editing in if !editing { commit() } }
        }
    }
}
