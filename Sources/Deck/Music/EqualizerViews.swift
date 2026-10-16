import SwiftUI

struct EqualizerTile: View {
    @ObservedObject var eq: Equalizer
    /// Smaller sliders and fewer words, for the menu bar panel and quick panel.
    var compact = false
    @State private var imported: String?

    var body: some View {
        Tile {
            EQHeader(eq: eq)
            if !eq.on && eq.problem == nil && !compact {
                Text("Shape the sound of your whole Mac. macOS will ask once to let Deck hear it.").font(F.label).foregroundStyle(C.text2)
            }
            if let p = eq.problem {
                Text(p).font(F.label).foregroundStyle(C.warn).fixedSize(horizontal: false, vertical: true)
                if p.contains("System Settings") {
                    Button("Open Settings") { NSWorkspace.shared.open(Equalizer.permissionPane) }.buttonStyle(.pill)
                }
            }
            EQBands(eq: eq, compact: compact)
            if Equalizer.fineTuneAvailable && !compact {
                HStack(spacing: 8) {
                    Button("Import from FineTune") { imported = eq.importFineTune() }.buttonStyle(.pill)
                    if let imported { Text(imported).font(F.label).foregroundStyle(C.text2).fixedSize(horizontal: false, vertical: true) }
                }
            }
            if !compact {
                TileLabel(text: "Volume per app").padding(.top, 4)
                AppVolumes(eq: eq)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct EQHeader: View {
    @ObservedObject var eq: Equalizer
    var body: some View {
        HStack {
            TileLabel(text: "Equalizer")
            Spacer()
            Toggle("Equalizer", isOn: Binding(get: { eq.on }, set: { eq.setOn($0) })).toggleStyle(.switch).controlSize(.small).labelsHidden()
                .help("Turn the equalizer on or off")
        }
    }
}

/// Presets and the ten band sliders.
struct EQBands: View {
    @ObservedObject var eq: Equalizer
    var compact = false

    var body: some View {
        let height: CGFloat = compact ? 84 : 120
        VStack(alignment: .leading, spacing: 10) {
            WrapLayout(spacing: 6) {
                ForEach(eq.allPresets, id: \.0) { name, g in
                    TabPill(title: name, selected: eq.gains == g) { eq.preset(g) }
                }
            }
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(0..<10, id: \.self) { i in
                    VStack(spacing: 6) {
                        if !compact { Text(String(format: "%+.0f", eq.gains[i])).font(F.mono(10)).foregroundStyle(C.text2) }
                        VerticalSlider(value: Binding(get: { eq.gains[i] }, set: { eq.gains[i] = $0 }), height: height)
                            .accessibilityLabel("\(Self.label(Equalizer.bands[i])) Hz")
                        Text(Self.label(Equalizer.bands[i])).font(F.mono(compact ? 9 : 10)).foregroundStyle(C.muted)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private static func label(_ hz: Float) -> String { hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))" }
}

/// A thin vertical bar for one EQ band (−12…+12 dB). Drag to set, double-click for 0.
struct VerticalSlider: View {
    @Binding var value: Float
    let height: CGFloat
    var range: ClosedRange<Float> = -12...12
    @Environment(\.accent) private var accent

    var body: some View {
        GeometryReader { g in
            let h = g.size.height
            let span = range.upperBound - range.lowerBound
            let y = { (v: Float) in h * CGFloat((range.upperBound - v) / span) }
            ZStack(alignment: .top) {
                Capsule().fill(C.line).frame(width: 4)
                // Fill from the 0 dB line to the value, so boosts and cuts read at a glance.
                Rectangle().fill(accent.accent)
                    .frame(width: 4, height: abs(y(value) - y(0)))
                    .offset(y: min(y(value), y(0)))
                Rectangle().fill(C.border).frame(width: 10, height: 1).offset(y: y(0))
                Circle().fill(C.text).frame(width: 12, height: 12).offset(y: y(value) - 6)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                let v = range.upperBound - Float(d.location.y / h) * span
                value = min(range.upperBound, max(range.lowerBound, v.rounded()))
            })
            .onTapGesture(count: 2) { value = 0 }
        }
        .frame(width: 24, height: height)
        .accessibilityElement()
        .accessibilityValue("\(Int(value)) decibels")
        .accessibilityAdjustableAction { dir in value = min(range.upperBound, max(range.lowerBound, value + (dir == .increment ? 1 : -1))) }
    }
}

/// Lays out children left to right, wrapping onto new lines (for preset pills).
struct WrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        rows(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i, p) in rows(bounds.width, subviews).points.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowH = max(rowH, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (points, CGSize(width: maxX, height: y + rowH))
    }
}

/// Every app making sound right now, each with its own volume. Refreshes while on screen.
struct AppVolumes: View {
    @ObservedObject var eq: Equalizer
    @Environment(\.accent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if eq.apps.isEmpty {
                Text("Nothing else is playing right now.").font(F.label).foregroundStyle(C.muted)
            }
            ForEach(eq.apps) { app in
                Row(divider: app != eq.apps.last) {
                    if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                    Text(app.name).font(F.body).lineLimit(1).frame(width: 96, alignment: .leading)
                    Slider(value: Binding(get: { eq.volume(app) }, set: { eq.setVolume(app, ($0 * 20).rounded() / 20) }), in: 0...1)
                        .tint(accent.accent).controlSize(.small).accessibilityLabel("\(app.name) volume")
                        .disabled(!eq.on)
                    Text("\(Int(eq.volume(app) * 100))%").font(F.mono(11)).foregroundStyle(C.text2).frame(width: 36, alignment: .trailing)
                }
            }
            if !eq.on && !eq.apps.isEmpty {
                HStack {
                    Text("Turn on the equalizer to change each app's volume.").font(F.label).foregroundStyle(C.muted)
                    Spacer()
                    Button("Turn on") { eq.setOn(true) }.buttonStyle(.pill)
                }
                .padding(.top, 6)
            }
        }
        .task {
            while !Task.isCancelled {
                eq.refreshApps()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }
}
