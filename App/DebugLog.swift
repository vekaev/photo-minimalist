import AppKit
import os
import SwiftUI

/// Diagnostics, kept for the next investigation: `.background(WindowProbe())` logs window moves/resizes,
/// `.logSize("name")` logs a view's size changes. Read with:
///   /usr/bin/log stream --level info --predicate 'subsystem == "app.horizonleveler"'
enum Log {
    static let layout = Logger(subsystem: "app.horizonleveler", category: "layout")
}

/// Logs the hosting window's frame whenever it moves or resizes, and its content size.
struct WindowProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ProbeView: NSView {
        private var tokens: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            guard let window else { return }
            Log.layout.info("window attached frame=\(NSStringFromRect(window.frame), privacy: .public) movableByBackground=\(window.isMovableByWindowBackground, privacy: .public)")
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak window] n in
                    guard let window else { return }
                    Log.layout.info("window \(n.name.rawValue, privacy: .public) frame=\(NSStringFromRect(window.frame), privacy: .public) content=\(NSStringFromSize(window.contentLayoutRect.size), privacy: .public)")
                })
            }
        }
    }
}

extension View {
    /// Logs this view's size whenever it changes.
    func logSize(_ label: String) -> some View {
        background(GeometryReader { geo in
            Color.clear
                .onAppear { Log.layout.info("\(label, privacy: .public) size=\(NSStringFromSize(geo.size), privacy: .public)") }
                .onChange(of: geo.size) { old, new in
                    Log.layout.info("\(label, privacy: .public) size \(NSStringFromSize(old), privacy: .public) -> \(NSStringFromSize(new), privacy: .public)")
                }
        })
    }
}
