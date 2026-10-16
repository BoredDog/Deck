import SwiftUI

/// Text on split-flap cards, like an airport departure board. Digits and letters flip when they change;
/// ":" becomes two dots and spaces stay put. `color` picks each character's colour by position.
struct SplitFlap: View {
    let text: String
    var size: CGFloat = 40
    var color: (Int) -> Color = { _ in C.lime }

    var body: some View {
        HStack(spacing: size * 0.07) {
            ForEach(Array(text.enumerated()), id: \.offset) { i, ch in
                switch ch {
                case ":":
                    VStack(spacing: size * 0.2) {
                        Circle().frame(width: size * 0.1, height: size * 0.1)
                        Circle().frame(width: size * 0.1, height: size * 0.1)
                    }
                    .foregroundStyle(color(i).opacity(0.85))
                    .frame(width: size * 0.22)
                case " ":
                    Color.clear.frame(width: size * 0.2, height: 1)
                default:
                    FlapCard(value: String(ch), size: size, color: color(i))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// One card. On change the old top half falls forward (darkening as it turns), then the new bottom half lands.
private struct FlapCard: View {
    let value: String
    let size: CGFloat
    let color: Color
    @State private var current: String
    @State private var previous: String
    @State private var topAngle = 0.0      // falling flap (old top half): 0 → -90
    @State private var bottomAngle = 0.0   // landing flap (new bottom half): 90 → 0

    init(value: String, size: CGFloat, color: Color) {
        self.value = value
        self.size = size
        self.color = color
        _current = State(initialValue: value)
        _previous = State(initialValue: value)
    }

    private var w: CGFloat { size * 0.7 }
    private var h: CGFloat { size }
    private var radius: CGFloat { size * 0.12 }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                half(current, top: true)
                half(previous, top: false)
            }
            VStack(spacing: 0) {
                half(previous, top: true)
                    .overlay(Color.black.opacity(-topAngle / 90 * 0.6))
                    .rotation3DEffect(.degrees(topAngle), axis: (1, 0, 0), anchor: .bottom, perspective: 0.4)
                    .opacity(topAngle <= -89 ? 0 : 1)
                half(current, top: false)
                    .overlay(Color.black.opacity(bottomAngle / 90 * 0.6))
                    .rotation3DEffect(.degrees(bottomAngle), axis: (1, 0, 0), anchor: .top, perspective: 0.4)
                    .opacity(bottomAngle >= 89 ? 0 : 1)
            }
            // The split across the middle, with the little hinge notches real flaps have at each side.
            Rectangle().fill(Color.black).frame(height: max(1, size * 0.035))
            HStack {
                Capsule().fill(Color.black).frame(width: size * 0.05, height: size * 0.12)
                Spacer()
                Capsule().fill(Color.black).frame(width: size * 0.05, height: size * 0.12)
            }
            .padding(.horizontal, -size * 0.01)
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(C.border, lineWidth: 1))
        .onChange(of: value) { _, new in flip(to: new) }
    }

    private func half(_ ch: String, top: Bool) -> some View {
        Text(ch)
            .font(.system(size: size * 0.74, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .frame(width: w, height: h)
            .frame(width: w, height: h / 2, alignment: top ? .top : .bottom)
            .clipped()
            .background(top ? Color(hex: 0x181818) : Color(hex: 0x131313))
    }

    private func flip(to new: String) {
        guard new != current else { return }
        previous = current
        current = new
        topAngle = 0
        bottomAngle = 90
        withAnimation(.easeIn(duration: 0.15)) { topAngle = -90 }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.72).delay(0.15)) { bottomAngle = 0 }
        // Once it has landed, both back halves show the new value.
        Task { try? await Task.sleep(for: .milliseconds(450)); previous = current; topAngle = 0 }
    }
}

/// A flip clock (24-hour, or 12-hour with AM/PM in Settings). Hours and AM/PM are lime, minutes and seconds white.
/// Only updates while it's on screen.
struct FlipClock: View {
    var size: CGFloat = 30
    @AppStorage("clock24") private var twentyFour = true
    private static func format(_ pattern: String) -> DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = pattern; return f
    }
    private static let hm24 = format("HH:mm"), hm12 = format("hh:mm"), ampm = format("a"), s = format("ss")

    var body: some View {
        // Tick on the exact second (not one second after the view appeared), so it matches the Mac's clock.
        TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: Date.timeIntervalSinceReferenceDate.rounded(.down)), by: 1)) { ctx in
            HStack(alignment: .lastTextBaseline, spacing: size * 0.22) {
                // "HH:mm": positions 0–1 are the hours.
                SplitFlap(text: (twentyFour ? Self.hm24 : Self.hm12).string(from: ctx.date), size: size) { $0 < 2 ? C.lime : C.text }
                VStack(alignment: .leading, spacing: 0) {
                    if !twentyFour {
                        Text(Self.ampm.string(from: ctx.date))
                            .font(.system(size: size * 0.32, weight: .semibold, design: .monospaced)).foregroundStyle(C.lime)
                    }
                    Text(Self.s.string(from: ctx.date))
                        .font(.system(size: size * 0.42, weight: .medium, design: .monospaced))
                        .foregroundStyle(C.text.opacity(0.8)).monospacedDigit()
                }
            }
        }
    }
}
