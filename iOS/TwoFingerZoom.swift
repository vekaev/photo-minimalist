import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Two fingers on the editor's canvas: pinch to zoom (at the fingers) and move to pan, in one gesture.
///
/// A UIKit recognizer on the window, offered only touches that land inside this (background) view and on the
/// editor's own screen (not a sheet over it). It never cancels or delays touches, so the canvas's one-finger
/// SwiftUI gestures (swipe, crop handles, two-point picker) keep working; the editor pauses them while two
/// fingers are down. SwiftUI's MagnifyGesture can't do this: it doesn't follow the fingers, so no pan.
struct TwoFingerZoom: UIViewRepresentable {
    enum Phase { case began, changed, ended }
    /// Phase, the fingers' scale since they started moving, their centroid in this view's coordinates.
    var onChange: (Phase, CGFloat, CGPoint) -> Void

    func makeUIView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onChange = onChange
        return v
    }

    func updateUIView(_ v: CatcherView, context: Context) { v.onChange = onChange }

    static func dismantleUIView(_ v: CatcherView, coordinator: ()) { v.detach() }

    final class CatcherView: UIView, UIGestureRecognizerDelegate {
        var onChange: ((Phase, CGFloat, CGPoint) -> Void)?
        private let recognizer = TwoTouchRecognizer()
        private weak var host: UIView?
        private var last = CGPoint.zero

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            recognizer.addTarget(self, action: #selector(fire))
            recognizer.delegate = self
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesEnded = false
        }

        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            if let w = window { w.addGestureRecognizer(recognizer); host = w }
        }

        func detach() {
            host?.removeGestureRecognizer(recognizer)
            host = nil
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard bounds.contains(touch.location(in: self)) else { return false }
            // Only this screen's own views: not a sheet, popover or menu over the photo.
            if let root = screenRoot, let v = touch.view, !v.isDescendant(of: root) { return false }
            return true
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        private var screenRoot: UIView? {
            var r: UIResponder? = self
            while let n = r {
                if let vc = n as? UIViewController { return vc.view }
                r = n.next
            }
            return nil
        }

        @objc private func fire() {
            switch recognizer.state {
            case .began:
                last = recognizer.centroid(in: self)
                onChange?(.began, 1, last)
            case .changed:
                last = recognizer.centroid(in: self)
                onChange?(.changed, recognizer.scale, last)
            case .ended, .cancelled, .failed:
                onChange?(.ended, recognizer.scale, last)
            default:
                break
            }
        }
    }
}

/// Recognizes once two touches are down and one of them has moved a few points; reports their distance ratio
/// and centroid until either lifts.
final class TwoTouchRecognizer: UIGestureRecognizer {
    private var down: [UITouch] = []
    private var startPoints: [CGPoint] = []
    private var startDistance: CGFloat = 0

    var scale: CGFloat { down.count == 2 && startDistance > 0 ? distance / startDistance : 1 }

    func centroid(in view: UIView) -> CGPoint {
        guard !down.isEmpty else { return .zero }
        let pts = down.map { $0.location(in: view) }
        return CGPoint(x: pts.map(\.x).reduce(0, +) / CGFloat(pts.count), y: pts.map(\.y).reduce(0, +) / CGFloat(pts.count))
    }

    private var distance: CGFloat {
        let a = down[0].location(in: nil), b = down[1].location(in: nil)
        return hypot(a.x - b.x, a.y - b.y)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for t in touches {
            if down.count < 2 { down.append(t) } else { ignore(t, for: event) }
        }
        if down.count == 2, state == .possible { startPoints = down.map { $0.location(in: nil) } }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard down.count == 2 else { return }
        if state == .possible {
            guard startPoints.count == 2 else { return }
            let moved = zip(down, startPoints).map { t, s in
                let p = t.location(in: nil)
                return hypot(p.x - s.x, p.y - s.y)
            }.max() ?? 0
            if moved > 4 {
                startDistance = max(distance, 1)
                state = .began
            }
        } else if state == .began || state == .changed {
            state = .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches, as: .ended) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches, as: .cancelled) }

    private func lift(_ touches: Set<UITouch>, as end: UIGestureRecognizer.State) {
        if state == .began || state == .changed {
            state = end
        } else {
            down.removeAll { touches.contains($0) }
            startPoints = []
            if down.isEmpty { state = .failed }
        }
    }

    override func reset() {
        super.reset()
        down = []
        startPoints = []
        startDistance = 0
    }
}
