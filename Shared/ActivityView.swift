import SwiftUI

/// The folder's activity, newest first, grouped by day ("like git log"), with Revert.
/// Mac: a sheet (View ▸ History, ⌘Y, or "Show all activity…" in a photo's history). iPhone: ⋯ ▸ History.
struct ActivityView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    /// The photo "Only this photo" filters to (the open one); nil hides the toggle.
    var photoID: String?
    @State private var query = ""
    @State private var onlyThis = false
    /// Waiting for "… was edited later — revert it…?"
    @State private var pending: JournalEntry?
    @State private var warning = ""

    private var entries: [JournalEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return library.activity.filter { e in
            if onlyThis, let photoID, !e.files.contains(photoID) { return false }
            guard !q.isEmpty else { return true }
            return e.summary.lowercased().contains(q) || e.action.rawValue.lowercased().contains(q)
                || e.files.contains { $0.lowercased().contains(q) }
        }
    }

    /// Entries by day, newest day first.
    private var days: [(day: Date, entries: [JournalEntry])] {
        let cal = Calendar.current
        var out: [(day: Date, entries: [JournalEntry])] = []
        for e in entries {
            let d = cal.startOfDay(for: e.date)
            if out.last?.day == d { out[out.count - 1].entries.append(e) } else { out.append((d, [e])) }
        }
        return out
    }

    var body: some View {
        content
            .task { library.loadActivity() }
            .alert("Edited later", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
                Button("Revert") { if let e = pending { library.revert(e) }; pending = nil }
                Button("Cancel", role: .cancel) { pending = nil }
            } message: { Text(warning) }
            .overlay(alignment: .bottom) { toast }
    }

    #if os(macOS)
    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("History").font(.headline)
                Spacer()
                if photoID != nil {
                    Toggle("Only this photo", isOn: $onlyThis).toggleStyle(.checkbox).font(.callout)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            TextField("Search by file or action", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 16).padding(.bottom, 10)
            Divider()
            list
        }
        .frame(width: 520, height: 640)
    }
    #else
    private var content: some View {
        NavigationStack {
            list
                .searchable(text: $query, prompt: "File or action")
                .navigationTitle("History")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                    if photoID != nil {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(onlyThis ? "All photos" : "This photo") { onlyThis.toggle() }
                        }
                    }
                }
        }
    }
    #endif

    private var list: some View {
        List {
            if entries.isEmpty, !library.activityLoading {
                Text(library.activity.isEmpty ? "Nothing yet. Everything you do in this folder shows up here." : "No matches.")
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
            ForEach(days, id: \.day) { day in
                Section {
                    ForEach(day.entries) { e in row(e) }
                } header: {
                    Text(dayTitle(day.day)).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            if library.activityHasMore {
                Button("Show older") { library.loadActivity(more: true) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .onAppear { library.loadActivity(more: true) }
                    .listRowSeparator(.hidden)
            } else if library.activityLoading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
    }

    private func dayTitle(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }

    @ViewBuilder private func row(_ e: JournalEntry) -> some View {
        let r = ActivityRow(entry: e, photo: library.photo(e.files.first), onRevert: { tryRevert(e) }, onShow: { show(e) })
        #if os(macOS)
        r.contextMenu {
            Button("Revert") { tryRevert(e) }.disabled(!e.isRevertible)
            Button("Show Photo") { show(e) }.disabled(library.photo(e.files.first) == nil)
        }
        #else
        r.contentShape(Rectangle())
            .onTapGesture { show(e) }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if e.isRevertible { Button("Revert") { tryRevert(e) }.tint(.gray) }
            }
        #endif
    }

    private func tryRevert(_ e: JournalEntry) {
        guard e.isRevertible else { library.toast = e.notRevertibleNote; return }
        if let w = library.revertWarning(e) { warning = w; pending = e } else { library.revert(e) }
    }

    private func show(_ e: JournalEntry) {
        guard let id = e.files.first else { return }
        guard library.photo(id) != nil else { library.showPhoto(id); return }   // toasts "isn't in this folder"
        dismiss()
        #if os(macOS)
        library.showPhoto(id)
        #else
        // Let the sheet go before the editor covers the screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { library.showPhoto(id) }
        #endif
    }

    /// Toasts from Revert, shown in the sheet (the window's own toast is behind it).
    private var toast: some View {
        ZStack {
            if let text = library.toast {
                Text(text)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.primary.opacity(0.09)))
                    .padding(.bottom, 16)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: library.toast)
        .allowsHitTesting(false)
    }
}

/// "12:04  Leveled DSCF0015 −0.4°" with a tiny thumbnail of the first photo; "3 photos" under batches.
private struct ActivityRow: View {
    let entry: JournalEntry
    let photo: Photo?
    let onRevert: () -> Void
    let onShow: () -> Void
    @State private var image: CGImage?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.date, format: .dateTime.hour().minute())
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    Text(entry.summary).font(.callout).lineLimit(1).truncationMode(.middle)
                }
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
            #if os(macOS)
            if hovering {
                HStack(spacing: 6) {
                    if entry.isRevertible { pill("Revert", action: onRevert) }
                    if photo != nil { pill("Show", action: onShow) }
                }
            }
            #endif
        }
        .padding(.vertical, 3)
        #if os(macOS)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        #endif
        .task(id: photo?.url) {
            guard let photo else { image = nil; return }
            image = await ImageCache.shared.image(for: photo.url, rawCompanion: photo.rawCompanion, maxPixel: 160)
        }
    }

    private var detail: String? {
        var parts: [String] = []
        if entry.files.count > 1 { parts.append("\(entry.files.count) photos") }
        if let note = entry.notRevertibleNote { parts.append(note) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var side: CGFloat {
        #if os(macOS)
        28
        #else
        40
        #endif
    }

    private var thumbnail: some View {
        ZStack {
            Color.primary.opacity(0.06)
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    #if os(macOS)
    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption.weight(.medium))
                .padding(.horizontal, 9).frame(height: 22)
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
    #endif
}
