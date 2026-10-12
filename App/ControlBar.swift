import AppKit
import SwiftUI

/// The look of one control in the preview's bar: a 28 pt icon, plus a short title when "Show labels" is on.
struct ControlLabel: View {
    let symbol: String
    let title: String
    let labels: Bool

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: symbol).frame(width: 28, height: 28)
            if labels { Text(title).font(.callout).lineLimit(1).fixedSize().padding(.trailing, 6) }
        }
        .contentShape(Rectangle())
    }

    /// Width it takes, so the bar knows how many fit before the "»" menu.
    static func width(_ title: String, labels: Bool) -> Double {
        guard labels else { return 28 }
        let font = NSFont.preferredFont(forTextStyle: .callout)
        return 28 + 6 + ceil((title as NSString).size(withAttributes: [.font: font]).width)
    }
}

/// "Customize Controls": Finder-like. The bar on top (drag to reorder, − or drag out to remove), the
/// available controls below (+ or drag in), Show labels, Restore Defaults, Done.
struct CustomizeControlsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PhotoControl.macKey) private var raw = PhotoControl.defaultValue(.mac)
    @AppStorage(PhotoControl.macLabelsKey) private var labels = false
    @State private var overBar = false
    @State private var overAvailable = false

    private var chosen: [PhotoControl] { PhotoControl.parse(raw, on: .mac) }
    private var available: [PhotoControl] { PhotoControl.all(on: .mac).filter { !chosen.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Customize Controls").font(.headline)
                Text("Drag to reorder. Drag a control out or click − to remove it; click + or drag it in to add it. Keyboard shortcuts work either way.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            area("In the bar", targeted: overBar) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(chosen) { c in
                            chip(c, inBar: true)
                                .draggable(c.rawValue) { chip(c, inBar: true) }
                                .dropDestination(for: String.self) { items, _ in insert(items, before: c) }
                        }
                        if chosen.isEmpty {
                            Text("Drag controls here").font(.callout).foregroundStyle(.tertiary).padding(.horizontal, 8)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 72)
            }
            .dropDestination(for: String.self) { items, _ in insert(items, before: nil) } isTargeted: { overBar = $0 }

            area("Available", targeted: overAvailable) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(available) { c in
                        chip(c, inBar: false).draggable(c.rawValue) { chip(c, inBar: false) }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
            }
            .dropDestination(for: String.self) { items, _ in remove(items) } isTargeted: { overAvailable = $0 }

            Toggle("Show labels", isOn: $labels)

            HStack {
                Button("Restore Defaults") { raw = PhotoControl.defaultValue(.mac); labels = false }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600)
        .tint(.primary)
    }

    private func area<Content: View>(_ title: String, targeted: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.raised.opacity(targeted ? 0.9 : 0.4), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(targeted ? Color.primary.opacity(0.5) : Theme.line))
        }
    }

    private func chip(_ c: PhotoControl, inBar: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: c.symbol).frame(width: 18)
            Text(c.title).font(.callout).lineLimit(1).fixedSize()
            if let s = c.shortcut { Text(s).font(.caption).foregroundStyle(.tertiary).fixedSize() }
            Button {
                var list = chosen
                if inBar { list.removeAll { $0 == c } } else { list.append(c) }
                raw = PhotoControl.serialize(list)
            } label: {
                Image(systemName: inBar ? "minus.circle" : "plus.circle").foregroundStyle(.secondary)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(inBar ? "Remove from the bar" : "Add to the bar")
        }
        .padding(.leading, 8).padding(.trailing, 4).frame(height: 30)
        .background(Theme.ground, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Drop in the bar: moves (or adds) the dragged control before `target`, or to the end.
    private func insert(_ items: [String], before target: PhotoControl?) -> Bool {
        guard let c = items.first.flatMap(PhotoControl.init(rawValue:)), c != target else { return false }
        var list = chosen
        list.removeAll { $0 == c }
        let i = target.flatMap { list.firstIndex(of: $0) } ?? list.endIndex
        list.insert(c, at: i)
        raw = PhotoControl.serialize(list)
        return true
    }

    /// Drop on Available: takes it out of the bar.
    private func remove(_ items: [String]) -> Bool {
        guard let c = items.first.flatMap(PhotoControl.init(rawValue:)), chosen.contains(c) else { return false }
        raw = PhotoControl.serialize(chosen.filter { $0 != c })
        return true
    }
}
