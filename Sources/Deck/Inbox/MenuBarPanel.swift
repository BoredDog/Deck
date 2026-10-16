import SwiftUI
import SwiftData

/// Tiles the menu bar panel and the quick panel can show. Each panel keeps its own comma-separated list of the ones turned on.
enum PanelTile: String, CaseIterable, Identifiable {
    case focus, next, today, download, nowPlaying, equalizer, note, clipboard, awake, tasks, weather, mac, drop
    var id: String { rawValue }

    static let menuBarKey = "menuBarTiles", quickPanelKey = "quickPanelTiles"
    static let menuBar: [PanelTile] = [.focus, .next, .today, .download, .nowPlaying, .equalizer, .note, .clipboard, .awake]
    static let quickPanel: [PanelTile] = [.focus, .next, .today, .tasks, .note, .download, .nowPlaying, .clipboard, .awake, .weather, .mac, .drop]
    /// Everything but clipboard history, which stays private unless asked for.
    static let defaults = allCases.filter { $0 != .clipboard }.map(\.rawValue).joined(separator: ",")

    var name: String {
        switch self {
        case .focus: "Focus timer"
        case .next: "Next event"
        case .today: "Classes and deadlines"
        case .download: "Current download"
        case .nowPlaying: "Now playing"
        case .equalizer: "Equalizer"
        case .note: "Quick note"
        case .clipboard: "Clipboard history"
        case .awake: "Keep awake"
        case .tasks: "Today's tasks"
        case .weather: "Weather"
        case .mac: "Mac status"
        case .drop: "Drop spots"
        }
    }

    /// Tiles added after someone customised their panels are switched on once, so they can find them.
    static func addNewTiles() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "panelTilesAddedToday") else { return }
        d.set(true, forKey: "panelTilesAddedToday")
        for key in [menuBarKey, quickPanelKey] { if let list = d.string(forKey: key) { d.set(set(.today, true, in: list), forKey: key) } }
    }

    static func isOn(_ t: PanelTile, in list: String) -> Bool { list.split(separator: ",").contains { $0 == t.rawValue } }

    static func set(_ t: PanelTile, _ on: Bool, in list: String) -> String {
        var s = Set(list.split(separator: ",").map(String.init))
        if on { s.insert(t.rawValue) } else { s.remove(t.rawValue) }
        return allCases.map(\.rawValue).filter(s.contains).joined(separator: ",")
    }
}

/// The small panel under the menu bar icon.
struct MenuBarPanel: View {
    @ObservedObject private var awake = KeepAwake.shared
    @Query(filter: #Predicate<Activity> { !$0.read }) private var unread: [Activity]
    @AppStorage(PanelTile.menuBarKey) private var tiles = PanelTile.defaults

    var body: some View {
        let on = { PanelTile.isOn($0, in: tiles) }
        VStack(spacing: 8) {
            if on(.focus) || on(.next) {
                HStack(alignment: .top, spacing: 8) {
                    if on(.focus) { FocusTile().frame(maxHeight: .infinity) }
                    if on(.next) { NextTile().frame(maxHeight: .infinity) }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if on(.today) { StudyTodayTile() }
            if on(.download) { DownloadTile() }
            if on(.nowPlaying) { NowPlayingTile() }
            if on(.equalizer) { CollapsedEqualizer() }
            if on(.note) { QuickNoteTile() }
            if on(.clipboard) { ClipboardTile() }
            if on(.awake) { Tile { KeepAwakeControls() }.fixedSize(horizontal: false, vertical: true) }
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

/// On/off switches for each tile of a panel, for Settings.
struct PanelTileSwitches: View {
    let key: String
    let tiles: [PanelTile]
    @AppStorage private var list: String

    init(key: String, tiles: [PanelTile]) {
        self.key = key
        self.tiles = tiles
        _list = AppStorage(wrappedValue: PanelTile.defaults, key)
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(tiles) { t in
                Row(divider: t != tiles.last) {
                    Text(t.name).font(F.body)
                    Spacer()
                    Toggle(t.name, isOn: Binding(get: { PanelTile.isOn(t, in: list) }, set: { list = PanelTile.set(t, $0, in: list) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
        }
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
                .help(focus.running ? "Stop this focus session" : "Start a focus session")
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
                Text("Nothing coming up.").font(F.body).foregroundStyle(C.text2)
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
    /// Tap the card to see every app making sound, each with its own volume.
    @State private var expanded = false
    var body: some View {
        VStack(spacing: 8) {
            NowPlayingCard(height: 150) { expanded.toggle() }  // no animation: it makes the menu bar window drift
            if expanded {
                Tile {
                    TileLabel(text: "Playing now")
                    AppVolumes(eq: Equalizer.shared)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct QuickNoteTile: View {
    @State private var note = ""
    var body: some View {
        Tile {
            TextField("Jot a note, press Return to save", text: $note)
                .deckField()
                .onSubmit { NoteFiles.appendToInbox(note); note = "" }
                .help("Saves to your Inbox note in Notes")
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct ClipboardTile: View {
    var limit = 3
    @ObservedObject private var clipboard = Clipboard.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let shown = Array(clipboard.items.prefix(limit))
        Tile {
            HStack {
                TileLabel(text: "Copied lately")
                Spacer()
                if clipboard.items.count > limit {
                    // Everything else lives in its own window, so the panel stays short.
                    Button("Show all \(clipboard.items.count)") { NSApp.activate(ignoringOtherApps: true); openWindow(id: "clipboard") }
                        .buttonStyle(.plain).font(F.label).foregroundStyle(C.text2)
                        .help("Open everything you copied lately in its own window")
                }
                if !shown.isEmpty { Button("Clear") { clipboard.clear() }.buttonStyle(.pill).help("Forget everything copied") }
            }
            if shown.isEmpty {
                Text(clipboard.on ? "Things you copy show up here for a day." : "Clipboard history is off. Turn it on in Settings.").font(F.label).foregroundStyle(C.text2)
            }
            list(shown)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func list(_ shown: [Clipboard.Item]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, item in
                Button { clipboard.copy(item) } label: {
                    Row(divider: i < shown.count - 1) {
                        Text(clock(item.date)).font(F.mono(11)).foregroundStyle(C.muted)
                        if let data = item.image, let img = NSImage(data: data) {
                            Image(nsImage: img).resizable().scaledToFill().frame(width: 28, height: 28)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            Text("Picture").font(F.label).foregroundStyle(C.text2)
                        } else {
                            Text(item.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").font(F.label).lineLimit(1)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Click to copy again")
            }
        }
    }
}
