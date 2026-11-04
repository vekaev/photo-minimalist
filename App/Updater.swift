import Combine
import Sparkle
import SwiftUI

/// Updates from GitHub Releases through Sparkle: once a day it reads the latest release's appcast.xml,
/// and when there's a newer version it shows the notes, downloads the DMG, checks its EdDSA signature
/// (the private key lives in the owner's keychain, see scripts/release.sh), replaces the app and relaunches.
/// Mac only: iPhone and iPad apps can only update through the App Store or TestFlight.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private var updater: SPUUpdater { controller.updater }
    @Published private(set) var canCheck = false
    private var token: AnyCancellable?

    private init() {
        token = updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).sink { [weak self] in self?.canCheck = $0 }
    }

    func checkForUpdates() { updater.checkForUpdates() }

    /// Settings ▸ General ▸ "Check for updates automatically".
    var automaticallyChecks: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { objectWillChange.send(); updater.automaticallyChecksForUpdates = newValue }
    }

    var lastCheck: Date? { updater.lastUpdateCheckDate }

    static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}

/// App menu ▸ "Check for Updates…", disabled while a check is already running.
struct CheckForUpdatesButton: View {
    @ObservedObject private var updater = Updater.shared
    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }.disabled(!updater.canCheck)
    }
}

/// The updates row in Settings ▸ General.
struct UpdatePreferences: View {
    @ObservedObject private var updater = Updater.shared
    var body: some View {
        Section {
            Toggle("Check for updates automatically", isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 }))
            LabeledContent("Version \(Updater.version)") {
                Button("Check Now") { updater.checkForUpdates() }.disabled(!updater.canCheck)
            }
        } footer: {
            Text(updater.lastCheck.map { "Last checked \($0.formatted(.relative(presentation: .named)))." } ?? "New versions come from the app's GitHub releases.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
