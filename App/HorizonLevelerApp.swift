import SwiftUI

@main
struct HorizonLevelerApp: App {
    @State private var library = Library()

    var body: some Scene {
        WindowGroup("Horizon Leveler") {
            ContentView()
                .environment(library)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .frame(minWidth: 980, minHeight: 640)
                .onAppear { library.restoreLastFolder() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    library.saveNow()
                }
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { library.chooseFolder() }.keyboardShortcut("o")
                Button("Export Leveled Photos…") { library.showExport = true }
                    .keyboardShortcut("e")
                    .disabled(library.toExport.isEmpty)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { library.undo() }.keyboardShortcut("z").disabled(!library.canUndo)
                Button("Redo") { library.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!library.canRedo)
            }
        }
    }
}
