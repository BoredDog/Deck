import SwiftUI
import UniformTypeIdentifiers

enum TileStyle { case plain, lime, accent }

/// One idea per tile. 12pt radius, 16pt padding, 0.5pt border that brightens on hover.
struct Tile<Content: View>: View {
    var style: TileStyle = .plain
    @ViewBuilder var content: Content
    @Environment(\.accent) private var accent
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(16)
            .background(background)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(borderColor, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(style == .lime ? C.onLime : C.text)
            .onHover { hover = $0 }
            .animation(.easeInOut(duration: 0.2), value: hover)
    }

    private var background: Color {
        switch style {
        case .plain: C.tile
        case .lime: C.lime
        case .accent: accent.surface
        }
    }

    private var borderColor: Color {
        switch style {
        case .plain: hover ? C.borderHover : C.border
        case .lime: C.lime
        case .accent: hover ? accent.accent.opacity(0.5) : accent.border
        }
    }
}

struct TileLabel: View {
    let text: String
    var onLime = false
    @Environment(\.accent) private var accent
    var body: some View {
        Text(text).font(F.label).foregroundStyle(onLime ? C.onLime.opacity(0.7) : C.text2)
    }
}

struct BigNumber: View {
    let text: String
    var body: some View { Text(text).font(F.big).tracking(-0.8) }
}

/// Thin 4px progress bar. Lime by default because progress is a win.
struct Bar4: View {
    let value: Double
    var color: Color = C.lime
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(C.line)
                Capsule().fill(color).frame(width: max(0, min(1, value)) * g.size.width)
            }
        }
        .frame(height: 4)
        .animation(.easeInOut(duration: 0.2), value: value)
    }
}

struct Dot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 8, height: 8) }
}

/// Rows are separated by thin lines, not boxes.
struct Row<Content: View>: View {
    var divider = true
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) { content }.padding(.vertical, 8)
            if divider { Rectangle().fill(C.line).frame(height: 0.5) }
        }
    }
}

/// Pill-shaped secondary button using the theme fill and border.
struct PillButtonStyle: ButtonStyle {
    @Environment(\.accent) private var accent
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(F.ui(12, medium: true))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(accent.fill))
            .overlay(Capsule().strokeBorder(accent.border, lineWidth: 0.5))
            .foregroundStyle(accent.soft)
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .animation(.easeInOut(duration: 0.2), value: configuration.isPressed)
    }
}

/// The single main action on a screen: light pill, black text. No generic blue.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(F.ui(14, medium: true))
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(Capsule().fill(C.text))
            .foregroundStyle(Color.black)
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.35)
            .animation(.easeInOut(duration: 0.2), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PillButtonStyle { static var pill: PillButtonStyle { .init() } }
extension ButtonStyle where Self == PrimaryButtonStyle { static var primary: PrimaryButtonStyle { .init() } }

/// Drop files here or click to pick them.
struct DropZone: View {
    let prompt: String
    var allowFolders = true
    var multiple = true
    let onFiles: ([URL]) -> Void
    @Environment(\.accent) private var accent
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc").font(.system(size: 22, weight: .regular)).foregroundStyle(accent.soft)
            Text(prompt).font(F.ui(14)).foregroundStyle(C.text)
            Text("or click to choose").font(F.label).foregroundStyle(C.text2)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
        .background(RoundedRectangle(cornerRadius: 12).fill(targeted ? accent.surface : C.tile))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(targeted ? accent.accent : C.border, style: StrokeStyle(lineWidth: 0.5, dash: [4, 4])))
        .contentShape(Rectangle())
        .onTapGesture { pick() }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            Task {
                var urls: [URL] = []
                for p in providers {
                    if let url = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                       let u = URL(dataRepresentation: url, relativeTo: nil) { urls.append(u) }
                }
                await MainActor.run { if !urls.isEmpty { onFiles(urls) } }
            }
            return true
        }
        .animation(.easeInOut(duration: 0.2), value: targeted)
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = allowFolders
        panel.allowsMultipleSelection = multiple
        if panel.runModal() == .OK { onFiles(panel.urls) }
    }
}

/// A screen header: title + one plain sentence.
struct ScreenHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(F.ui(22, medium: true)).foregroundStyle(C.text)
            Text(subtitle).font(F.body).foregroundStyle(C.text2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Plain-language byte counts ("1.2 GB").
func bytes(_ n: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowsNonnumericFormatting = false // "0 KB", not "Zero KB"
    return f.string(fromByteCount: n)
}

/// Mono timestamp like a log line.
func clock(_ d: Date) -> String {
    d.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
}
