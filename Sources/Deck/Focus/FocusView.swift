import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import ServiceManagement

struct FocusView: View {
    @ObservedObject private var timer = FocusTimer.shared
    @Query private var sessions: [FocusSession]
    @Environment(\.accent) private var accent
    @AppStorage(FocusKey.minutes) private var minutes = 25

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ScreenHeader(title: "Focus", subtitle: "One thing at a time. Deck keeps distractions out of the way.")
            // Two equal halves; a Grid let wide text fields stretch one column past the window edge.
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    timerTile.frame(maxWidth: .infinity)
                    VStack(spacing: 8) { streakTile; weekTile }.frame(maxWidth: .infinity)
                }
                .frame(height: 360)
                HStack(alignment: .top, spacing: 8) {
                    BlockTile().frame(maxWidth: .infinity)
                    VStack(spacing: 8) { SoundTile(); BreaksTile() }.frame(maxWidth: .infinity)
                }
                DNDTile()
            }
            MusicSection()
        }
    }

    // MARK: timer

    private var timerTile: some View {
        Tile(style: .accent) {
            TileLabel(text: timer.phase == .rest ? "Break" : "Focus")
            ZStack {
                Circle().stroke(accent.border, lineWidth: 6)
                Circle().trim(from: 0, to: timer.progress)
                    .stroke(C.lime, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.2), value: timer.progress)
                VStack(spacing: 4) {
                    Text(timer.remainingText).font(F.mono(44))
                    if timer.paused { Text(timer.pausedForSleep ? "Paused while your Mac slept" : "Paused").font(F.label).foregroundStyle(C.text2) }
                }
            }
            .frame(width: 190, height: 190)
            .frame(maxWidth: .infinity)
            HStack(spacing: 6) {
                ForEach([15, 25, 45, 60], id: \.self) { m in
                    Chip(text: "\(m) min", selected: minutes == m) { timer.setLength(m) }
                }
            }
            .disabled(timer.running)
            .frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                if !timer.running {
                    Button("Start focus") { timer.start(minutes: minutes) }.buttonStyle(.primary)
                } else {
                    Button(timer.paused ? "Resume" : "Pause") { timer.paused ? timer.resume() : timer.pause() }.buttonStyle(.pill)
                    Button(timer.phase == .rest ? "Skip break" : "Stop") { timer.stop() }.buttonStyle(.pill)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var streakTile: some View {
        let streak = FocusStats.streak(sessions)
        return Tile {
            TileLabel(text: "Focus streak")
            BigNumber(text: streak == 1 ? "1 day" : "\(streak) days").foregroundStyle(streak > 0 ? C.lime : C.text)
            Text(streak > 0 ? "Keep it going!" : "Finish one session to start a streak.").font(F.label).foregroundStyle(C.text2)
        }
    }

    private var weekTile: some View {
        let days = FocusStats.weekByDay(sessions)
        let total = days.reduce(0, +), best = days.max() ?? 0
        return Tile {
            TileLabel(text: "Focus time this week")
            BigNumber(text: total >= 60 ? "\(total / 60)h \(total % 60)m" : "\(total)m")
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(days.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(days[i] == best && best > 0 ? C.lime : (days[i] > 0 ? accent.soft : C.line))
                        .frame(height: max(3, 36 * CGFloat(days[i]) / CGFloat(max(best, 1))))
                }
            }
            .frame(height: 36)
        }
    }
}

/// A small selectable pill for picking one option.
private struct Chip: View {
    let text: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.accent) private var accent

    var body: some View {
        Button(action: action) {
            Text(text).font(F.ui(12, medium: selected))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(selected ? accent.fill : .clear))
                .overlay(Capsule().strokeBorder(selected ? accent.accent.opacity(0.6) : accent.border, lineWidth: 0.5))
                .foregroundStyle(selected ? accent.soft : C.text2)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: block distractions

private struct BlockTile: View {
    @AppStorage(FocusKey.apps) private var appsRaw = ""
    @AppStorage(FocusKey.sites) private var sitesRaw = ""
    @State private var site = ""
    @State private var siteError = false
    @State private var helper = SMAppService.Status.notRegistered

    private var apps: [String] { appsRaw.split(separator: "\n").map(String.init) }
    private var sites: [String] { sitesRaw.split(separator: "\n").map(String.init) }

    var body: some View {
        Tile {
            TileLabel(text: "Block distractions")
            Text("While you focus, these stay out of the way.").font(F.label).foregroundStyle(C.muted)
            ForEach(apps, id: \.self) { id in
                Row {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
                        Text(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")).font(F.body)
                    } else {
                        Text(id).font(F.body)
                    }
                    Spacer()
                    remove { appsRaw = apps.filter { $0 != id }.joined(separator: "\n") }
                }
            }
            Menu("Add an app") {
                ForEach(runningApps, id: \.0) { id, name in Button(name) { addApp(id) } }
                Divider()
                Button("Choose from Applications…", action: pickApp)
            }
            .menuStyle(.borderlessButton).fixedSize()
            ForEach(sites, id: \.self) { s in
                Row {
                    Text(s).font(F.body)
                    Spacer()
                    remove { sitesRaw = sites.filter { $0 != s }.joined(separator: "\n") }
                }
            }
            TextField("Add a website, like youtube.com", text: $site)
                .textFieldStyle(.plain).font(F.body)
                .onSubmit(addSite)
            if siteError {
                Text("That doesn't look like a website. Try youtube.com").font(F.label).foregroundStyle(C.warn)
            } else if !sites.isEmpty {
                helperRow
            }
        }
        .onAppear { helper = Blocker.helper.status }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            helper = Blocker.helper.status   // back from System Settings
        }
    }

    /// One-time helper setup, so blocking websites stops asking for the password.
    @ViewBuilder private var helperRow: some View {
        switch helper {
        case .enabled:
            Text("Websites are blocked without asking for your password.").font(F.label).foregroundStyle(C.muted)
        case .requiresApproval:
            Text("Turn on Deck in System Settings → General → Login Items to finish.").font(F.label).foregroundStyle(C.text2)
            Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(.pill)
        default:
            Text("Blocking websites asks for your Mac password when focus starts and ends. Set it up once to stop that.")
                .font(F.label).foregroundStyle(C.muted)
            Button("Set up blocking") { Blocker.setUpHelper(); helper = Blocker.helper.status }.buttonStyle(.pill)
        }
    }

    private func remove(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(C.muted) }
            .buttonStyle(.plain).accessibilityLabel("Remove")
    }

    private var runningApps: [(String, String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { a in a.bundleIdentifier.map { ($0, a.localizedName ?? $0) } }
            .filter { !apps.contains($0.0) }
            .sorted { $0.1 < $1.1 }
    }

    private func addApp(_ id: String) {
        guard !apps.contains(id) else { return }
        appsRaw = (apps + [id]).joined(separator: "\n")
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }.forEach(addApp)
    }

    private func addSite() {
        guard let d = Blocker.validDomains([site]).first else { siteError = !site.isEmpty; return }
        if !sites.contains(d) { sitesRaw = (sites + [d]).joined(separator: "\n") }
        site = ""
        siteError = false
    }
}

// MARK: sounds, breaks, do not disturb

private struct SoundTile: View {
    @AppStorage(FocusKey.noise) private var noise = Sounds.Kind.off.rawValue
    @AppStorage(FocusKey.volume) private var volume = 0.4
    @Environment(\.accent) private var accent

    var body: some View {
        Tile {
            TileLabel(text: "Background sound")
            HStack(spacing: 6) {
                ForEach(Sounds.Kind.allCases, id: \.self) { k in
                    Chip(text: k.rawValue, selected: noise == k.rawValue) { noise = k.rawValue }
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.1").foregroundStyle(C.muted)
                Slider(value: $volume, in: 0...1).tint(accent.accent)
            }
            Text("Plays while you focus.").font(F.label).foregroundStyle(C.muted)
        }
        .onChange(of: noise) { if FocusTimer.shared.focusing { Sounds.shared.play() } }
        .onChange(of: volume) { Sounds.shared.setVolume(Float(volume)) }
    }
}

private struct BreaksTile: View {
    @AppStorage(FocusKey.breaksOn) private var on = false
    @AppStorage(FocusKey.breaksEvery) private var every = 20
    @Environment(\.accent) private var accent

    var body: some View {
        Tile {
            Toggle(isOn: $on) { TileLabel(text: "Break reminders") }.toggleStyle(.switch).tint(accent.accent)
            HStack(spacing: 6) {
                ForEach([20, 30, 45, 60], id: \.self) { m in
                    Chip(text: "every \(m) min", selected: every == m) { every = m }
                }
            }
            .disabled(!on)
            Text("Rest your eyes, stretch, have some water. Quiet during meetings.").font(F.label).foregroundStyle(C.muted)
        }
        .onChange(of: on) {
            if on { Task { await BreakReminders.shared.askPermission() } }
            BreakReminders.shared.reschedule()
        }
        .onChange(of: every) { BreakReminders.shared.reschedule() }
    }
}

private struct DNDTile: View {
    @AppStorage(FocusKey.dndOn) private var onName = ""
    @AppStorage(FocusKey.dndOff) private var offName = ""

    var body: some View {
        Tile {
            TileLabel(text: "Do Not Disturb (optional)")
            Text("Make a Shortcut that turns Do Not Disturb on and one that turns it off, then type their names here.")
                .font(F.label).foregroundStyle(C.muted)
            HStack(spacing: 16) {
                TextField("Shortcut for when focus starts", text: $onName).textFieldStyle(.plain).font(F.body)
                TextField("Shortcut for when focus ends", text: $offName).textFieldStyle(.plain).font(F.body)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
