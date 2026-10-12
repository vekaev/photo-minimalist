import AppKit
import SwiftUI

/// Trackpad pinch, scroll, smart zoom, ⌥-clicks and ⌘= for the preview canvas, read with a local event monitor
/// (SwiftUI on the Mac has no scroll-wheel gesture, and MagnifyGesture doesn't say where the pinch is).
/// Put it in the canvas's `.background`: events are offered only for this window, with the location in the
/// canvas's own (top-left) coordinates. The handler returns true to consume an event.
struct CanvasEvents: NSViewRepresentable {
    var handler: (NSEvent, CGPoint) -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let v = MonitorView()
        v.handler = handler
        return v
    }

    func updateNSView(_ v: MonitorView, context: Context) { v.handler = handler }

    static func dismantleNSView(_ v: MonitorView, coordinator: ()) { v.stop() }

    final class MonitorView: NSView {
        var handler: ((NSEvent, CGPoint) -> Bool)?
        private var monitor: Any?

        override var isFlipped: Bool { true }
        /// Never in the way of clicks: it only listens.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { start() } else { stop() }
        }

        private func start() {
            guard monitor == nil else { return }
            let mask: NSEvent.EventTypeMask = [.scrollWheel, .magnify, .smartMagnify, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]
            monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] e in
                guard let self, let w = self.window, e.window === w, !self.isHiddenOrHasHiddenAncestor, let h = self.handler else { return e }
                let p = e.type == .keyDown ? .zero : self.convert(e.locationInWindow, from: nil)
                return h(e, p) ? nil : e
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

extension PreviewZoom {
    /// The Mac's zoom input for a canvas: pinch (at the pointer), smart zoom (two-finger double-tap) and
    /// ⌥-double-click (fit ⇄ 2×), ⌥-scroll (zoom at the pointer), two-finger scroll (pan while zoomed), ⌘=.
    /// `p` is in canvas coordinates. Returns true when the event was used.
    mutating func handle(_ e: NSEvent, at p: CGPoint) -> Bool {
        let inside = CGRect(origin: .zero, size: area).contains(p)
        switch e.type {
        case .magnify:
            guard inside else { return false }
            zoom(to: scale * (1 + e.magnification), at: p)
            return true
        case .smartMagnify:
            guard inside else { return false }
            withAnimation(.easeOut(duration: 0.18)) { toggle(at: p) }
            return true
        case .scrollWheel:
            guard inside else { return false }
            let k: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 10
            if e.modifierFlags.contains(.option) {
                // Wheel / fingers up zooms in.
                let d = (abs(e.scrollingDeltaY) >= abs(e.scrollingDeltaX) ? e.scrollingDeltaY : e.scrollingDeltaX) * k
                zoom(to: scale * exp(d * 0.01), at: p)
                return true
            }
            guard isZoomed else { return false }
            pan(by: CGSize(width: e.scrollingDeltaX * k, height: e.scrollingDeltaY * k))
            return true
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            // ⌥-clicks on the photo belong to zoom (nothing else in the canvas uses ⌥), so the first click of a
            // ⌥-double-click doesn't place a point or move the crop frame.
            guard inside, e.modifierFlags.contains(.option) else { return false }
            if e.type == .leftMouseDown, e.clickCount == 2 { withAnimation(.easeOut(duration: 0.18)) { toggle(at: p) } }
            return true
        case .keyDown:
            // ⌘= zooms in too (the menu item shows ⌘+, which needs ⇧ on most keyboards).
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            guard mods == .command, e.charactersIgnoringModifiers == "=", e.window?.isKeyWindow == true else { return false }
            withAnimation(.easeOut(duration: 0.15)) { step(1) }
            return true
        default:
            return false
        }
    }
}
