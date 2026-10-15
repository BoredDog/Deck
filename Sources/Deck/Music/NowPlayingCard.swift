import SwiftUI

/// What's playing, with the album cover filling the whole card. Used on Home, in Focus and in the menu bar.
struct NowPlayingCard: View {
    @ObservedObject private var music = NowPlaying.shared
    var height: CGFloat = 200
    /// Tapping the card (not its buttons) calls this, e.g. to show every app that's playing.
    var onTap: (() -> Void)?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let art = music.artwork {
                // The cover sits in an overlay so its size can't push the card wider than its frame.
                Color.clear.overlay { Image(nsImage: art).resizable().scaledToFill() }.clipped()
                // A flat dim (no gradient) keeps white text readable on any cover.
                Color.black.opacity(0.5)
            } else {
                C.tile
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Spacer()
                    if let app = music.app { Text(app).font(F.mono(11)).foregroundStyle(C.text.opacity(0.7)) }
                }
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text(music.title ?? "Nothing playing").font(F.ui(17, medium: true)).foregroundStyle(C.text).lineLimit(1)
                    Text(music.artist ?? " ").font(F.label).foregroundStyle(C.text.opacity(0.75)).lineLimit(1)
                }
                HStack(spacing: 12) {
                    RoundControl(icon: "backward.fill", size: 30, label: "Previous") { music.previous() }
                    RoundControl(icon: music.isPlaying ? "pause.fill" : "play.fill", size: 40, label: music.isPlaying ? "Pause" : "Play",
                                 filled: true) { music.playPause() }
                    RoundControl(icon: "forward.fill", size: 30, label: "Next") { music.next() }
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(C.border, lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { onTap?() }
        .showsNowPlaying()
    }
}

private struct RoundControl: View {
    let icon: String
    let size: CGFloat
    let label: String
    var filled = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.36, weight: .medium))
                .foregroundStyle(filled ? Color.black : C.text)
                .frame(width: size, height: size)
                .background(Circle().fill(filled ? C.text : Color.black.opacity(hover ? 0.7 : 0.45)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .onHover { hover = $0 }
        .animation(.easeInOut(duration: 0.2), value: hover)
    }
}
