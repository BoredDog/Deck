import SwiftUI

/// Text shown on split-flap cards, like an airport departure board. Digits flip when they change; ":" and spaces stay put.
struct SplitFlap: View {
    let text: String
    var size: CGFloat = 40

    var body: some View {
        HStack(spacing: size * 0.08) {
            ForEach(Array(text.enumerated()), id: \.offset) { _, ch in
                if ch == ":" || ch == " " {
                    Text(String(ch)).font(.system(size: size * 0.8, weight: .medium, design: .monospaced))
                        .foregroundStyle(C.lime.opacity(0.8)).frame(width: size * 0.35)
                } else {
                    FlapCard(value: String(ch), size: size)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// One card. On change the old top half falls forward, then the new bottom half lands.
private struct FlapCard: View {
    let value: String
    let size: CGFloat
    @State private var current: String
    @State private var previous: String
    @State private var topAngle = 0.0      // the falling flap (old value, top half): 0 → -90
    @State private var bottomAngle = 0.0   // the landing flap (new value, bottom half): 90 → 0

    init(value: String, size: CGFloat) {
        self.value = value
        self.size = size
        _current = State(initialValue: value)
        _previous = State(initialValue: value)
    }

    private var w: CGFloat { size * 0.72 }
    private var h: CGFloat { size }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                half(current, top: true)       // behind the falling flap: the new top
                half(previous, top: false)     // behind the landing flap: the old bottom
            }
            VStack(spacing: 0) {
                half(previous, top: true)
                    .rotation3DEffect(.degrees(topAngle), axis: (1, 0, 0), anchor: .bottom, perspective: 0.5)
                    .opacity(topAngle <= -89 ? 0 : 1)
                half(current, top: false)
                    .rotation3DEffect(.degrees(bottomAngle), axis: (1, 0, 0), anchor: .top, perspective: 0.5)
                    .opacity(bottomAngle >= 89 ? 0 : 1)
            }
            // The seam across the middle of a real flap.
            Rectangle().fill(Color.black).frame(height: max(1, size * 0.03))
        }
        .frame(width: w, height: h)
        .onChange(of: value) { _, new in flip(to: new) }
    }

    private func half(_ ch: String, top: Bool) -> some View {
        Text(ch)
            .font(.system(size: size * 0.78, weight: .medium, design: .monospaced))
            .foregroundStyle(C.lime)
            .frame(width: w, height: h)
            .frame(width: w, height: h / 2, alignment: top ? .top : .bottom)
            .clipped()
            .background(
                UnevenRoundedRectangle(topLeadingRadius: top ? 5 : 0, bottomLeadingRadius: top ? 0 : 5,
                                       bottomTrailingRadius: top ? 0 : 5, topTrailingRadius: top ? 5 : 0)
                    .fill(top ? Color(hex: 0x161616) : Color(hex: 0x121212))
            )
    }

    private func flip(to new: String) {
        guard new != current else { return }
        previous = current
        current = new
        topAngle = 0
        bottomAngle = 90
        withAnimation(.easeIn(duration: 0.14)) { topAngle = -90 }
        withAnimation(.easeOut(duration: 0.16).delay(0.14)) { bottomAngle = 0 }
        // Once landed, the back halves both show the new value.
        Task { try? await Task.sleep(for: .milliseconds(320)); previous = current; topAngle = 0 }
    }
}

/// A flip clock (24-hour, or 12-hour with AM/PM in Settings): hours and minutes on flip cards, seconds ticking quietly beside them.
/// Only updates while it's on screen.
struct FlipClock: View {
    var size: CGFloat = 30
    /// Fixed format and locale, so it's always 24-hour whatever the Mac's region says.
    @AppStorage("clock24") private var twentyFour = true
    private static func format(_ pattern: String) -> DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = pattern; return f
    }
    private static let hm24 = format("HH:mm"), hm12 = format("hh:mm"), ampm = format("a")
    private static let s = format("ss")

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(alignment: .lastTextBaseline, spacing: size * 0.2) {
                SplitFlap(text: (twentyFour ? Self.hm24 : Self.hm12).string(from: ctx.date), size: size)
                Text(Self.s.string(from: ctx.date) + (twentyFour ? "" : " " + Self.ampm.string(from: ctx.date)))
                    .font(.system(size: size * 0.45, weight: .medium, design: .monospaced))
                    .foregroundStyle(C.lime.opacity(0.75))
                    .monospacedDigit()
            }
        }
    }
}
