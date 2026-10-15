import SwiftUI
import SwiftData

/// The small panel under the menu bar icon.
struct MenuBarPanel: View {
    @ObservedObject private var awake = KeepAwake.shared
    @Query(filter: #Predicate<Activity> { !$0.read }) private var unread: [Activity]

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                FocusTile()
                NextTile()
            }
            .fixedSize(horizontal: false, vertical: true)
            DownloadTile()
            NowPlayingTile()
            EqualizerTile(eq: Equalizer.shared, compact: true)
            QuickNoteTile()
            ClipboardTile(limit: 10)
            Tile {
                KeepAwakeControls()
            }
            HStack {
                Text(unread.isEmpty ? "All caught up" : "\(unread.count) unread").font(F.mono(11)).foregroundStyle(C.text2)
                Spacer()
                Button("Open Deck") { MainWindow.open() }.buttonStyle(.primary)
            }
            .padding(.horizontal, 4)
        }
        .padding(8)
        .frame(width: 320)
        .background(C.bg)
        .foregroundStyle(C.text)
        .onAppear { Clipboard.shared.start() }
        .showsNowPlaying()
    }
}

// Pieces shared by the menu bar panel and the quick panel.

struct FocusTile: View {
    @ObservedObject private var focus = FocusTimer.shared
    var body: some View {
        Tile {
            TileLabel(text: "Focus")
            Text(focus.remainingText).font(F.mono(20))
            Button(focus.running ? "Stop" : "Start") { focus.running ? focus.stop() : focus.start() }.buttonStyle(.pill)
        }
    }
}

struct NextTile: View {
    @ObservedObject private var planner = Planner.shared
    var body: some View {
        Tile {
            TileLabel(text: "Next")
            if let e = planner.nextEvent {
                Text(e.title).font(F.body).lineLimit(2)
                Text(clock(e.start)).font(F.mono(11)).foregroundStyle(C.text2)
            } else {
                Text("Nothing coming up").font(F.body).foregroundStyle(C.text2)
            }
        }
    }
}

/// Shows only while something is downloading.
struct DownloadTile: View {
    @ObservedObject private var downloads = Downloads.shared
    var body: some View {
        if let d = downloads.items.first(where: { $0.status == "active" }) {
            Tile {
                HStack { Text(d.name).font(F.body).lineLimit(1); Spacer(); Text("\(bytes(d.speed))/s").font(F.mono(11)).foregroundStyle(C.text2) }
                Bar4(value: d.progress)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Shows only while a music app is open.
struct NowPlayingTile: View {
    @ObservedObject private var music = NowPlaying.shared
    /// Tap the tile to see every app making sound, each with its own volume.
    @State private var expanded = false
    var body: some View {
        Group {
            Tile {
                HStack {
                    Button { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(music.title ?? (music.app == nil ? "Nothing playing" : "Paused")).font(F.body).lineLimit(1)
                                Text(music.artist ?? "").font(F.label).foregroundStyle(C.text2).lineLimit(1)
                            }
                            Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 10)).foregroundStyle(C.muted)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show what's playing")
                    Spacer()
                    Button { music.previous() } label: { Image(systemName: "backward.fill") }.buttonStyle(.pill)
                    Button { music.playPause() } label: { Image(systemName: music.isPlaying ? "pause.fill" : "play.fill") }.buttonStyle(.pill)
                    Button { music.next() } label: { Image(systemName: "forward.fill") }.buttonStyle(.pill)
                }
                if expanded {
                    TileLabel(text: "Playing now")
                    AppVolumes(eq: Equalizer.shared)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct QuickNoteTile: View {
    @State private var note = ""
    var body: some View {
        Tile {
            TextField("Quick note, then press Enter", text: $note)
                .textFieldStyle(.plain).font(F.body)
                .onSubmit { NoteFiles.appendToInbox(note); note = "" }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct ClipboardTile: View {
    let limit: Int
    @ObservedObject private var clipboard = Clipboard.shared

    var body: some View {
        let shown = Array(clipboard.items.prefix(limit))
        Tile {
            HStack {
                TileLabel(text: "Copied lately")
                Spacer()
                if !shown.isEmpty { Button("Clear") { clipboard.clear() }.buttonStyle(.pill) }
            }
            if shown.isEmpty {
                Text(clipboard.on ? "Things you copy show up here for a day." : "Clipboard history is off. Turn it on in Settings.").font(F.label).foregroundStyle(C.text2)
            }
            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, item in
                    Button { clipboard.copy(item) } label: {
                        Row(divider: i < shown.count - 1) {
                            Text(clock(item.date)).font(F.mono(11)).foregroundStyle(C.muted)
                            Text(item.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Image · \(bytes(Int64(item.image?.count ?? 0)))")
                                .font(F.label).lineLimit(1)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Click to copy again")
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
