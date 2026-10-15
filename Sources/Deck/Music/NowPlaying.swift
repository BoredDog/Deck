import SwiftUI
import AppKit

/// Now playing from Spotify / Apple Music / YT Music. Only talks to apps that are already open, never launches them.
@MainActor final class NowPlaying: ObservableObject {
    static let shared = NowPlaying()
    @Published var title: String?
    @Published var artist: String?
    @Published var app: String?
    @Published var isPlaying = false
    @Published var artwork: URL?
    @Published var blocked = false   // the user said no to Automation for this app
    @AppStorage("musicAllowed") var allowed = false { didSet { objectWillChange.send(); start() } }

    private enum Player: String { case spotify = "com.spotify.client", music = "com.apple.Music", yt = "com.github.th-ch.youtube-music" }
    private var player: Player?
    private var timer: Timer?
    private let queue = DispatchQueue(label: "deck.nowplaying") // AppleScript can be slow; keep it off the main thread
    private static let ytAPI = "http://127.0.0.1:26538/api/v1"

    private init() { start() }

    /// Polling starts only after the user said yes in the Music tile.
    func start() {
        guard allowed, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in MainActor.assumeIsolated { NowPlaying.shared.poll() } }
        poll()
    }

    func playPause() { command(spotify: "playpause", yt: "toggle-play", key: 16) }
    func next() { command(spotify: "next track", yt: "next", key: 17) }
    func previous() { command(spotify: "previous track", yt: "previous", key: 18) }

    private func running() -> [Player] {
        let ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return [Player.spotify, .music, .yt].filter { ids.contains($0.rawValue) }
    }

    private func poll() {
        let open = running()
        guard !open.isEmpty else { clear(); return }
        let scriptable = open.filter { $0 != .yt }
        if scriptable.isEmpty { pollYT(); return }
        queue.async {
            var best: (Player, [String])?
            for p in scriptable {
                guard let r = Self.script(Self.statusScript(p)) else { continue }
                if r == "denied" { DispatchQueue.main.async { self.blocked = true }; continue }
                let parts = r.components(separatedBy: "\t")
                if best == nil || parts.first == "playing" { best = (p, parts) }
            }
            DispatchQueue.main.async {
                guard let (p, parts) = best, parts.count >= 3 else { self.clear(); self.app = scriptable.first.map(Self.name); return }
                self.blocked = false
                self.player = p
                self.app = Self.name(p)
                self.isPlaying = parts[0] == "playing"
                self.title = parts[1].isEmpty ? nil : parts[1]
                self.artist = parts[2]
                self.artwork = parts.count > 3 ? URL(string: parts[3]) : nil
            }
        }
    }

    /// The YouTube Music desktop app can expose a local API (its "API server" plugin). Without it, media keys still work.
    private func pollYT() {
        player = .yt
        app = Self.name(.yt)
        guard let url = URL(string: "\(Self.ytAPI)/song") else { return }
        URLSession.shared.dataTask(with: url) { data, resp, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async {
                guard (resp as? HTTPURLResponse)?.statusCode == 200, let json else { self.title = nil; self.artist = nil; return }
                self.title = json["title"] as? String
                self.artist = json["artist"] as? String
                self.isPlaying = !((json["isPaused"] as? Bool) ?? true)
                self.artwork = (json["imageSrc"] as? String).flatMap(URL.init(string:))
            }
        }.resume()
    }

    private func clear() {
        player = nil; app = nil; title = nil; artist = nil; artwork = nil; isPlaying = false
    }

    private func command(spotify cmd: String, yt: String, key: Int32) {
        switch player {
        case .spotify, .music:
            let id = player!.rawValue
            queue.async { _ = Self.script("tell application id \"\(id)\" to \(cmd)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.poll() }
        case .yt, nil:
            guard player == .yt, let url = URL(string: "\(Self.ytAPI)/\(yt)") else { Self.mediaKey(key); return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            URLSession.shared.dataTask(with: req) { _, resp, _ in
                if (resp as? HTTPURLResponse)?.statusCode != 204 && (resp as? HTTPURLResponse)?.statusCode != 200 {
                    DispatchQueue.main.async { Self.mediaKey(key) }
                }
            }.resume()
        }
    }

    /// Presses the keyboard's play / next / previous key. macOS may ask once to let Deck send keys.
    private static func mediaKey(_ key: Int32) {
        if !CGPreflightPostEventAccess() { CGRequestPostEventAccess(); return }
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = Int((key << 16) | ((down ? 0xa : 0xb) << 8))
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                               context: nil, subtype: 8, data1: data1, data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    nonisolated private static func name(_ p: Player) -> String {
        switch p { case .spotify: "Spotify"; case .music: "Apple Music"; case .yt: "YouTube Music" }
    }

    nonisolated private static func statusScript(_ p: Player) -> String {
        let art = p == .spotify ? " & tab & (artwork url of t)" : ""
        return """
        tell application id "\(p.rawValue)"
            if player state is stopped then return "stopped" & tab & "" & tab & ""
            set t to current track
            return (player state as string) & tab & (name of t) & tab & (artist of t)\(art)
        end tell
        """
    }

    /// Runs AppleScript. Returns "denied" when the user turned off Automation for Deck.
    nonisolated private static func script(_ source: String) -> String? {
        var err: NSDictionary?
        let out = NSAppleScript(source: source)?.executeAndReturnError(&err)
        if (err?[NSAppleScript.errorNumber] as? Int) == -1743 { return "denied" }
        return out?.stringValue
    }
}

/// Music player + equalizer section shown inside Focus.
struct MusicSection: View {
    @ObservedObject private var music = NowPlaying.shared
    @ObservedObject private var eq = Equalizer.shared

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Tile {
                HStack {
                    TileLabel(text: "Now playing")
                    Spacer()
                    if let app = music.app { Text(app).font(F.mono(11)).foregroundStyle(C.text2) }
                }
                if !music.allowed {
                    Text("Show what's playing in Spotify or Apple Music? macOS will ask once so Deck can control them.")
                        .font(F.label).foregroundStyle(C.text2)
                    Button("Allow") { music.allowed = true }.buttonStyle(.pill)
                } else if music.blocked {
                    Text("Turn on Deck in System Settings → Privacy & Security → Automation to control your music.")
                        .font(F.label).foregroundStyle(C.text2)
                }
                Text(music.title ?? "Nothing playing").font(F.ui(16, medium: true)).lineLimit(1)
                Text(music.artist ?? " ").font(F.label).foregroundStyle(C.text2).lineLimit(1)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Button { music.previous() } label: { Image(systemName: "backward.fill") }.buttonStyle(.pill)
                    Button { music.playPause() } label: { Image(systemName: music.isPlaying ? "pause.fill" : "play.fill") }.buttonStyle(.pill)
                    Button { music.next() } label: { Image(systemName: "forward.fill") }.buttonStyle(.pill)
                }
            }
            .frame(width: 260)
            EqualizerTile(eq: eq)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
