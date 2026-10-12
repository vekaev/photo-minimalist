import Foundation

/// Limits how many slow file reads run at once (memory cards choke on many parallel reads) and lets
/// what's on screen go first: waiting thumbnails are served newest-first, the background check after them.
actor ReadGate {
    static let shared = ReadGate(permits: 3)

    private var free: Int
    private var screen: [CheckedContinuation<Void, Never>] = []
    private var background: [CheckedContinuation<Void, Never>] = []

    init(permits: Int) { free = permits }

    func enter(onScreen: Bool) async {
        if free > 0 { free -= 1; return }
        await withCheckedContinuation { c in
            if onScreen { screen.append(c) } else { background.append(c) }
        }
    }

    func leave() {
        if let next = screen.popLast() { next.resume() }              // most recently requested thumbnail first
        else if !background.isEmpty { background.removeFirst().resume() }
        else { free += 1 }
    }
}
