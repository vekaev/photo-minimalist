import SwiftUI

/// The app's Settings window (⌘,), the standard Mac place for app-wide preferences, with General and Review tabs.
/// The side panel (S) keeps only what you change while looking at a photo. Values are stored in UserDefaults; open
/// tabs pick changes up (FolderWindows syncs them).
struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralPreferences().tabItem { Label("General", systemImage: "gearshape") }
            ReviewPreferences().tabItem { Label("Review", systemImage: "checkmark.circle") }
            AdvancedPreferences().tabItem { Label("Advanced", systemImage: "gearshape.2") }
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralPreferences: View {
    @AppStorage("reopenLastFolder") private var reopenLastFolder = true
    @AppStorage("cardAction") private var cardAction: CardAction = .ask
    @AppStorage("pairRaw") private var pairRaw = true
    @AppStorage(Library.confirmDeleteKey) private var confirmDelete = true
    @AppStorage(AppAppearance.key) private var appearance: AppAppearance = .system

    var body: some View {
        Form {
            Section {
                Toggle("Reopen folders at launch", isOn: $reopenLastFolder)
                Picker("When a memory card is inserted", selection: $cardAction) {
                    ForEach(CardAction.allCases) { Text($0.label).tag($0) }
                }
            }
            Section {
                Toggle("Show RAW + JPEG pairs as one photo", isOn: $pairRaw)
                Toggle("Ask before moving photos to the Trash", isOn: $confirmDelete)
            } footer: {
                Text("A pair like DSCF0015.JPG + .RAF shows the JPEG with a RAF mark; decisions and deletes apply to both. ⌘Z puts deleted photos back.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // Low importance, so last.
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: appearance) { _, a in a.apply() }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ReviewPreferences: View {
    @AppStorage("reviewOrder") private var reviewOrder: ReviewOrder = .shot
    @AppStorage("advanceAfterDecision") private var advanceAfterDecision = false
    @AppStorage("autoLevel") private var autoLevel = false
    @AppStorage("thumbFill") private var thumbFill = false

    var body: some View {
        Form {
            Section {
                Picker("Order", selection: $reviewOrder) {
                    ForEach(ReviewOrder.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Go to the next photo after leveling or keeping", isOn: $advanceAfterDecision)
            }
            Section {
                Toggle("Crop grid thumbnails to fill", isOn: $thumbFill)
            } footer: {
                Text("Off shows each whole photo in an equal tile, like Lightroom's grid.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Level tilted photos automatically", isOn: $autoLevel)
            } footer: {
                Text("Applies only to new folders. Off is recommended: suggestions stay suggestions until you decide.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Experimental, personal features. Everything they add stays hidden while they're off.
private struct AdvancedPreferences: View {
    @AppStorage(Library.labFixesKey) private var labFixes = false

    var body: some View {
        Form {
            Section {
                Toggle("Film scan fixes", isOn: $labFixes)
            } footer: {
                Text("Experimental: removes dark shutter bands near the frame edges of film scans (Leica M6).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
