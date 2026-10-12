import SwiftUI

/// View options for the photo in front of you, as a side panel that slides in and out (S, or the sliders
/// button). App-wide preferences are in the Settings window (⌘,, PreferencesWindow.swift).
/// Uses the same stored keys as the photo view, so changes apply instantly.
struct SettingsPanel: View {
    @Environment(Library.self) private var library

    @AppStorage("gridMode") private var gridMode: GridMode = .fine
    @AppStorage("horizontalOnly") private var horizontalOnly = true
    @AppStorage("showSuggestion") private var showSuggestion = true
    @AppStorage("showGuide") private var showGuide = true
    @AppStorage("showLoupes") private var showLoupes = true
    @AppStorage("compareMode") private var compare: CompareMode = .off
    @AppStorage("overlayOpacity") private var overlayOpacity = 0.5

    var body: some View {
        @Bindable var library = library
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("View").font(.headline)
                    Spacer()
                    Button { withAnimation { library.showSettings = false } } label: {
                        Image(systemName: "xmark").frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Close (S)")
                }

                group("Level") {
                    tip(Toggle("Suggested horizon", isOn: $showSuggestion),
                        "A dashed line where the detector thinks the horizon is, on photos it's sure are tilted.")
                    tip(Toggle("Guide line", isOn: $showGuide),
                        "A thin line across the photo that you drag up or down onto the horizon to see whether it's level.")
                    tip(Toggle("Loupes on the guide", isOn: Binding(get: { showGuide && showLoupes },
                                                                     set: { showLoupes = $0; if $0 { showGuide = true } })),
                        "Two ×5 magnifiers at the ends of the guide line. If the horizon sits exactly on the line in both, the photo is level. Turning this on also shows the guide line.")
                }

                group("Lines") {
                    Picker("Lines", selection: $gridMode) {
                        ForEach(GridMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    tip(Toggle("Horizontal only", isOn: $horizontalOnly),
                        "Draws only the horizontal lines over the photo, which is all you need to check a horizon.")
                }

                group("Compare") {
                    Picker("Compare", selection: $compare) {
                        ForEach(CompareMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.radioGroup).labelsHidden()
                    if compare == .overlay {
                        LabeledContent("Original") {
                            Slider(value: $overlayOpacity, in: 0...1)
                        }
                    }
                }

                if let id = library.openedID {
                    group("This photo") {
                        Button("Use suggested angle") { library.resetToDetected(id) }
                            .disabled(library.photo(id)?.detection == nil)
                        Button("Reset to original") { library.resetToOriginal([id]) }
                    }
                }

                Divider()
                // App-wide preferences (folders, memory card, review, appearance) live in the Settings window.
                SettingsLink {
                    Label("App Settings…  ⌘,", systemImage: "gearshape")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(18)
        }
        .background(Theme.panel)
    }

    /// A setting with a small ⓘ that explains it on hover and on click.
    private func tip<V: View>(_ control: V, _ text: String) -> some View {
        HStack(spacing: 6) {
            control
            InfoTip(text: text)
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption.weight(.medium)).foregroundStyle(.secondary).tracking(0.5)
            content()
        }
    }
}

/// ⓘ: shows a short explanation (tooltip on hover, popover on click).
struct InfoTip: View {
    let text: String
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle").font(.caption).foregroundStyle(.secondary)
                .frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(text)
        .popover(isPresented: $shown, arrowEdge: .leading) {
            Text(text).font(.callout).frame(width: 240, alignment: .leading).padding(12)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityLabel("About this setting")
    }
}
