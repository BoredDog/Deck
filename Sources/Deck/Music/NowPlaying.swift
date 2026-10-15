import SwiftUI
import AppKit

/// Now playing from any app (browsers too) through MediaRemote; falls back to Spotify / Apple Music / YT Music.
/// Only talks to apps that are already open, never launches them, and only while something shows what's playing.
@MainActor final class NowPlaying: ObservableObject {
    static let shared = NowPlaying()
    @Published var title: String?
    @Published var artist: String?
    @Published var app: String?
    @Published var isPlaying = false
    @Published var artwork: NSImage?
    @Published var blocked = false   // the user said no to Automation for this app
    @AppStorage("musicAllowed") var allowed = false { didSet { objectWillChange.send(); start() } }

    private enum Player: String { case spotify = "com.spotify.client", music = "com.apple.Music", yt = "com.github.th-ch.youtube-music" }
    private var player: Player?
    private var timer: Timer?
    private let queue = DispatchQueue(label: "deck.nowplaying") // osascript can be slow; wait for it off the main thread
    private var viewers = 0
    private static let ytAPI = "http://127.0.0.1:26538/api/v1"
    private static let session = URLSession(configuration: .ephemeral)

    private init() {
        startAdapter()
        start()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NowPlaying.shared.adapter?.terminate() }
        }
    }

    /// True while the MediaRemote reader runs; then no Automation permission is needed at all.
    var usesAdapter: Bool { adapter != nil }

    /// AppleScript polling runs only after the user said yes in the Music tile, without the MediaRemote reader,
    /// and while a Now Playing view is on screen.
    func start() {
        guard allowed, !usesAdapter, viewers > 0, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in MainActor.assumeIsolated { NowPlaying.shared.poll() } }
        poll()
    }

    /// Views showing what's playing call this on appear (true) and disappear (false).
    func viewing(_ on: Bool) {
        viewers = max(0, viewers + (on ? 1 : -1))
        if viewers == 0 { timer?.invalidate(); timer = nil } else { start() }
    }

    func playPause() { if !send(2) { command(spotify: "playpause", yt: "toggle-play", key: 16) } }
    func next() { if !send(4) { command(spotify: "next track", yt: "next", key: 17) } }
    func previous() { if !send(5) { command(spotify: "previous track", yt: "previous", key: 18) } }

    // MARK: MediaRemote (ungive/mediaremote-adapter, BSD-3): /usr/bin/perl may use MediaRemote, apps may not.

    private var adapter: Process?
    private var state: [String: Any] = [:]

    /// The bundled reader inside Deck.app, or Vendor/ during development.
    nonisolated static func adapterFiles() -> (script: String, framework: String)? {
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../Vendor/mediaremote-adapter").standardized.path
        let candidates = [
            (Bundle.main.path(forResource: "mediaremote-adapter", ofType: "pl"), Bundle.main.privateFrameworksPath.map { "\($0)/MediaRemoteAdapter.framework" }),
            ("\(dev)/bin/mediaremote-adapter.pl", "\(dev)/build/MediaRemoteAdapter.framework"),
        ]
        for case let (script?, framework?) in candidates
        where FileManager.default.fileExists(atPath: script) && FileManager.default.fileExists(atPath: framework) {
            return (script, framework)
        }
        return nil
    }

    private func startAdapter() {
        guard let files = Self.adapterFiles() else { return }
        // A reader left behind by a crashed Deck has launchd (pid 1) as its parent: stop it first.
        let stale = Process()
        stale.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        stale.arguments = ["-P", "1", "-f", "mediaremote-adapter.pl"]
        try? stale.run()
        stale.waitUntilExit()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [files.script, files.framework, "stream", "--debounce=100"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice   // stderr lines are non-fatal notices
        Task.detached {
            for try await line in out.fileHandleForReading.bytes.lines {
                await MainActor.run { NowPlaying.shared.received(line) }
            }
        }
        p.terminationHandler = { _ in
            // Broken on this macOS (or quit): don't relaunch it, use the AppleScript path instead.
            DispatchQueue.main.async { NowPlaying.shared.adapter = nil; NowPlaying.shared.start() }
        }
        do { try p.run(); adapter = p } catch { adapter = nil }
    }

    private func received(_ line: String) {
        guard let next = Self.merge(line: line, into: state) else { return }
        state = next
        let t = Self.track(from: state)
        guard t.title != nil else { clear(); return }
        title = t.title
        artist = t.artist
        isPlaying = t.playing
        app = t.bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
        artwork = t.artwork.flatMap(NSImage.init(data:))
    }

    /// Sends play/pause (2), next (4) or previous (5) through the reader. False when the reader isn't running.
    private func send(_ command: Int) -> Bool {
        guard usesAdapter, let files = Self.adapterFiles() else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [files.script, files.framework, "send", String(command)]
        return (try? p.run()) != nil
    }

    struct Track: Equatable { var title: String?; var artist: String?; var bundleID: String?; var playing = false; var artwork: Data? }

    /// Applies one `stream` line to the current state: a full payload replaces it, a diff updates it (null removes a key).
    nonisolated static func merge(line: String, into state: [String: Any]) -> [String: Any]? {
        guard let json = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              json["type"] as? String == "data", let payload = json["payload"] as? [String: Any] else { return nil }
        var next = (json["diff"] as? Bool) == true ? state : [:]
        for (k, v) in payload { next[k] = v is NSNull ? nil : v }
        return next
    }

    nonisolated static func track(from s: [String: Any]) -> Track {
        Track(title: (s["title"] as? String).flatMap { $0.isEmpty ? nil : $0 },
              artist: s["artist"] as? String,
              bundleID: s["parentApplicationBundleIdentifier"] as? String ?? s["bundleIdentifier"] as? String,
              playing: s["playing"] as? Bool ?? false,
              artwork: (s["artworkData"] as? String).flatMap { Data(base64Encoded: $0) })
    }

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
            }
        }
    }

    /// The YouTube Music desktop app can expose a local API (its "API server" plugin). Without it, media keys still work.
    private func pollYT() {
        player = .yt
        app = Self.name(.yt)
        guard let url = URL(string: "\(Self.ytAPI)/song") else { return }
        Self.session.dataTask(with: url) { data, resp, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async {
                guard (resp as? HTTPURLResponse)?.statusCode == 200, let json else { self.title = nil; self.artist = nil; return }
                self.title = json["title"] as? String
                self.artist = json["artist"] as? String
                self.isPlaying = !((json["isPaused"] as? Bool) ?? true)
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
            Self.session.dataTask(with: req) { _, resp, _ in
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
        return """
        tell application id "\(p.rawValue)"
            if player state is stopped then return "stopped" & tab & "" & tab & ""
            set t to current track
            return (player state as string) & tab & (name of t) & tab & (artist of t)
        end tell
        """
    }

    /// Runs AppleScript in osascript (NSAppleScript isn't safe off the main thread). Returns "denied" when the user
    /// turned off Automation for Deck. Call off the main thread: it waits for the script.
    nonisolated private static func script(_ source: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        if errText.contains("-1743") { return "denied" }
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
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
                if !music.usesAdapter && !music.allowed {
                    Text("Show what's playing in Spotify or Apple Music? macOS will ask once so Deck can control them.")
                        .font(F.label).foregroundStyle(C.text2)
                    Button("Allow") { music.allowed = true }.buttonStyle(.pill)
                } else if !music.usesAdapter && music.blocked {
                    Text("Turn on Deck in System Settings → Privacy & Security → Automation to control your music.")
                        .font(F.label).foregroundStyle(C.text2)
                }
                HStack(spacing: 10) {
                    if let art = music.artwork {
                        Image(nsImage: art).resizable().scaledToFill().frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(music.title ?? "Nothing playing").font(F.ui(16, medium: true)).lineLimit(1)
                        Text(music.artist ?? " ").font(F.label).foregroundStyle(C.text2).lineLimit(1)
                    }
                }
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
        .showsNowPlaying()
    }
}

extension View {
    /// Lets NowPlaying poll music apps only while this view is on screen.
    func showsNowPlaying() -> some View {
        onAppear { NowPlaying.shared.viewing(true) }.onDisappear { NowPlaying.shared.viewing(false) }
    }
}
