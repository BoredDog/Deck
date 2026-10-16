import SwiftUI

/// Everything you copied lately, opened from "Show all" in the menu bar or quick panel.
struct ClipboardWindow: View {
    @ObservedObject private var clipboard = Clipboard.shared
    @State private var copied: UUID?

    private var pictures: [Clipboard.Item] { clipboard.items.filter { $0.image != nil } }
    private var texts: [Clipboard.Item] { clipboard.items.filter { $0.image == nil } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    ScreenHeader(title: "Clipboard", subtitle: "Click anything to copy it again. Kept for a while, then forgotten.")
                    if !clipboard.items.isEmpty { Button("Clear all") { clipboard.clear() }.buttonStyle(.pill) }
                }
                if clipboard.items.isEmpty {
                    Tile {
                        Text(clipboard.on ? "Nothing copied lately." : "Clipboard history is off. Turn it on in Settings.")
                            .font(F.body).foregroundStyle(C.text2)
                    }
                    .frame(height: 70)
                }
                if !pictures.isEmpty {
                    TileLabel(text: "Pictures")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                        ForEach(pictures) { item in
                            ClipCell(item: item, copied: copied == item.id) { copy(item) } remove: { clipboard.remove(item) }
                        }
                    }
                }
                if !texts.isEmpty {
                    TileLabel(text: "Text")
                    Tile {
                        ForEach(Array(texts.enumerated()), id: \.element.id) { i, item in
                            ClipRow(item: item, copied: copied == item.id, last: i == texts.count - 1) { copy(item) } remove: { clipboard.remove(item) }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)
        }
        .frame(minWidth: 520, minHeight: 420)
        .background(C.bg)
        .foregroundStyle(C.text)
    }

    private func copy(_ item: Clipboard.Item) {
        clipboard.copy(item)
        copied = item.id
        Task { try? await Task.sleep(for: .seconds(1.2)); if copied == item.id { copied = nil } }
    }
}

private struct ClipCell: View {
    let item: Clipboard.Item
    let copied: Bool
    let copy: () -> Void
    let remove: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: copy) {
            ZStack(alignment: .bottomLeading) {
                Color.clear.overlay {
                    if let data = item.image, let img = NSImage(data: data) { Image(nsImage: img).resizable().scaledToFill() }
                }
                .clipped()
                Text(copied ? "Copied" : clock(item.date))
                    .font(F.mono(10)).foregroundStyle(copied ? C.onLime : C.text)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(copied ? C.lime : Color.black.opacity(0.6)))
                    .padding(6)
            }
            .frame(height: 110)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(hover ? C.borderHover : C.border, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) { if hover { RemoveButton(action: remove).padding(6) } }
        .onHover { hover = $0 }
        .help("Click to copy again")
    }
}

private struct ClipRow: View {
    let item: Clipboard.Item
    let copied: Bool
    let last: Bool
    let copy: () -> Void
    let remove: () -> Void
    @State private var hover = false

    var body: some View {
        Row(divider: !last) {
            Button(action: copy) {
                HStack(spacing: 10) {
                    Text(clock(item.date)).font(F.mono(11)).foregroundStyle(C.muted)
                    Text(item.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").font(F.body).lineLimit(2)
                    Spacer()
                    if copied { Text("Copied").font(F.label).foregroundStyle(C.lime) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Click to copy again")
            RemoveButton(action: remove).opacity(hover ? 1 : 0)
        }
        .onHover { hover = $0 }
    }
}

private struct RemoveButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.black.opacity(0.7)))
                .foregroundStyle(C.text)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove")
    }
}
