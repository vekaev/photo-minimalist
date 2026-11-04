import Foundation
import ServiceManagement

/// Opens the app when a memory card goes in while it isn't running. A tiny LaunchAgent inside the app
/// (Support/CardWatcher: a shell script launchd runs whenever /Volumes changes) opens the app with
/// `-launchedForCard YES`; the app then shows the card first (CardMonitor). Registered through SMAppService,
/// so it shows up in System Settings ▸ General ▸ Login Items & Extensions and goes away with the app.
/// While the app runs, CardMonitor handles cards itself; the agent's `open` only brings it forward.
@MainActor
enum CardWatcher {
    static let key = "cardWatcher"
    private static let service = SMAppService.agent(plistName: "app.horizonleveler.cardwatcher.plist")

    /// Settings: "Also when Photo Minimalist is closed" (on by default).
    static var wanted: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    static var status: SMAppService.Status { service.status }

    /// Registered exactly when wanted and cards open automatically. Called at launch and when settings change.
    static func sync() {
        let on = wanted && CardAction.current == .open
        if on { seedPresentCards() }
        do {
            switch (on, service.status) {
            case (true, .notRegistered), (true, .notFound): try service.register()
            case (false, .enabled), (false, .requiresApproval): try service.unregister()
            default: break
            }
        } catch {
            Library.log("card watcher: \(on ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
    }

    private static var stateFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/HorizonLeveler/cards-present")
    }

    /// A card was ejected while the app runs: forget it, so putting it back in counts as new for the script.
    static func cardRemoved(_ volume: URL) {
        guard let text = try? String(contentsOf: stateFile, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n").map(String.init)
        let kept = lines.filter { $0 != volume.path && $0 != volume.standardizedFileURL.path }
        guard kept.count != lines.count else { return }
        try? kept.map { $0 + "\n" }.joined().write(to: stateFile, atomically: true, encoding: .utf8)
    }

    /// The script launches the app only for cards that weren't in on its last run. Before its first run,
    /// note the cards that are in already, so they don't count as new on the next mount of anything.
    private static func seedPresentCards() {
        let state = stateFile, dir = state.deletingLastPathComponent()
        guard !FileManager.default.fileExists(atPath: state.path) else { return }
        let volumes = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        let cards = volumes.map { "/Volumes/" + $0 }.filter { FileManager.default.fileExists(atPath: $0 + "/DCIM") }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? (cards.map { $0 + "\n" }.joined()).write(to: state, atomically: true, encoding: .utf8)
    }

    /// The app was opened by the watcher for a card that just went in.
    static var launchedForCard: Bool { UserDefaults.standard.bool(forKey: "launchedForCard") }
}
