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

/// Pick one of a few options as pills, in Deck's style, instead of a macOS dropdown.
struct PillPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(String, Value)]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options.indices, id: \.self) { i in
                TabPill(title: options[i].0, selected: selection == options[i].1) { selection = options[i].1 }
            }
        }
    }
}

/// Deck's text field: a plain field on a black rounded box, instead of the macOS bordered box.
extension View {
    func deckField() -> some View {
        textFieldStyle(.plain).font(F.body)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(C.bg))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(C.border, lineWidth: 0.5))
    }
}

/// A small "− value +" pill instead of a macOS stepper.
struct PillStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    @Environment(\.accent) private var accent

    var body: some View {
        HStack(spacing: 8) {
            step(-1, "minus", "Less")
            Text("\(value)").font(F.mono(12)).foregroundStyle(C.text).frame(minWidth: 24)
            step(1, "plus", "More")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(accent.fill))
        .overlay(Capsule().strokeBorder(accent.border, lineWidth: 0.5))
    }

    private func step(_ d: Int, _ icon: String, _ name: String) -> some View {
        Button { value = min(max(value + d, range.lowerBound), range.upperBound) } label: {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(accent.soft)
                .frame(width: 16, height: 16).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(d < 0 ? value <= range.lowerBound : value >= range.upperBound)
        .accessibilityLabel(name)
    }
}

/// A button that pops a short native list of choices. The button itself keeps Deck's look
/// (style it with `.buttonStyle(...)`), unlike SwiftUI's Menu, which draws a macOS pull-down.
struct MenuButton<Label: View>: View {
    /// A title of "" adds a divider.
    let items: [(String, () -> Void)]
    @ViewBuilder var label: Label

    var body: some View { Button { pop() } label: { label } }

    private func pop() {
        let menu = NSMenu()
        for (title, run) in items {
            if title.isEmpty { menu.addItem(.separator()); continue }
            let action = MenuAction(run)
            let item = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: "")
            item.target = action
            item.representedObject = action // target is weak; this keeps the action alive
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

private final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

/// A dropdown in Deck's colours: a pill showing the current choice; tapping it unfolds the options right below.
struct DeckDropdown<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(String, Value)]
    @State private var open = false
    @Environment(\.accent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    Text(options.first { $0.1 == selection }?.0 ?? "").font(F.ui(12, medium: true))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(accent.fill))
                .overlay(Capsule().strokeBorder(accent.border, lineWidth: 0.5))
                .foregroundStyle(accent.soft)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(options.indices, id: \.self) { i in
                        DropdownRow(title: options[i].0, selected: options[i].1 == selection) {
                            selection = options[i].1
                            open = false
                        }
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 10).fill(C.bg))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(C.border, lineWidth: 0.5))
                .fixedSize()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: open)
    }
}

private struct DropdownRow: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hover = false
    @Environment(\.accent) private var accent

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).opacity(selected ? 1 : 0)
                Text(title).font(F.body)
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(hover ? accent.fill : .clear))
            .foregroundStyle(selected ? accent.soft : C.text)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
