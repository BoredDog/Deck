import SwiftUI

enum Place: String, CaseIterable, Identifiable {
    case home = "Home", files = "Files", find = "Find", mac = "Mac", downloads = "Downloads"
    case plan = "Plan", focus = "Focus", notes = "Notes", inbox = "Inbox"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home: "square.grid.2x2"
        case .files: "doc.on.doc"
        case .find: "magnifyingglass"
        case .mac: "gauge.with.dots.needle.33percent"
        case .downloads: "arrow.down.circle"
        case .plan: "calendar"
        case .focus: "timer"
        case .notes: "note.text"
        case .inbox: "tray"
        }
    }
}

struct RootView: View {
    @AppStorage("place") private var place = Place.home
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accent) private var accent

    var body: some View {
        // The native sidebar window: on Tahoe the sidebar floats and the traffic lights sit inside it.
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                ScrollView {
                    detail.padding(24).frame(maxWidth: .infinity, alignment: .topLeading)
                }
                StatusLine()
            }
            .background(C.bg)
            .foregroundStyle(C.text)
        }
        .toolbar(removing: .sidebarToggle)
        .navigationTitle("")
        // In the Dock (and ⌘Tab) only while the window is open; menu bar only otherwise.
        .onAppear {
            MainWindow.opener = openWindow
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }

    private var sidebar: some View {
        List(selection: Binding(get: { Optional(place) }, set: { if let p = $0 { place = p } })) {
            ForEach(Place.allCases) { p in
                Label(p.rawValue, systemImage: p.icon).font(F.ui(13)).tag(p)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            SettingsLink { Label("Settings", systemImage: "gearshape").font(F.ui(13)) }
                .buttonStyle(.plain).foregroundStyle(C.text2)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.bottom, 12)
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
    }

    @ViewBuilder private var detail: some View {
        switch place {
        case .home: HomeView()
        case .files: FilesView()
        case .find: FindView()
        case .mac: MacView()
        case .downloads: DownloadsView()
        case .plan: PlanView()
        case .focus: FocusView()
        case .notes: NotesView()
        case .inbox: InboxView()
        }
    }
}

/// Tiny low-contrast status line at the very bottom, with a blinking block cursor.
/// A quiet line at the bottom: one encouraging sentence a day, with your name. A timer shows on the right only while something runs.
struct StatusLine: View {
    @ObservedObject private var downloads = Downloads.shared
    @ObservedObject private var focus = FocusTimer.shared
    @AppStorage(UserName.key) private var name = UserName.fallback
    /// Picked when the window opens, so every open gets a new one.
    @State private var line = Encouragement.next()

    var body: some View {
        HStack {
            Text(Encouragement.sentence(line, name: name)).font(F.label)
            Spacer()
            if !summary.isEmpty { Text(summary).font(F.mono(11)) }
        }
        .foregroundStyle(C.muted)
        .padding(.horizontal, 16).padding(.vertical, 6)
        .overlay(alignment: .top) { Rectangle().fill(C.line).frame(height: 0.5) }
    }

    private var summary: String {
        var parts: [String] = []
        if focus.running { parts.append("focus \(focus.remainingText)") }
        let active = downloads.items.filter { $0.status == "active" }.count
        if active > 0 { parts.append("\(active) downloading") }
        return parts.joined(separator: " · ")
    }
}

/// What Deck calls you. Defaults to the first word of the Mac account's full name; changeable in Settings.
enum UserName {
    static let key = "displayName"
    static var fallback: String { NSFullUserName().split(separator: " ").first.map(String.init) ?? "" }
}

enum Encouragement {
    static let lines = [
        "small steps still count",
        "one thing at a time",
        "you've done hard things before",
        "progress, not perfect",
        "start small, keep going",
        "rest is part of the work",
        "a little today beats a lot someday",
        "be kind to yourself today",
        "you're doing better than you think",
        "focus on the next step",
        "done is better than perfect",
        "slow is still forward",
        "make today a good one",
        "you've got this",
        "breathe, then begin",
        "keep showing up",
    ]

    /// A different line from last time.
    static func next(defaults: UserDefaults = .standard) -> String {
        let last = defaults.string(forKey: "lastEncouragement")
        let line = lines.filter { $0 != last }.randomElement()!
        defaults.set(line, forKey: "lastEncouragement")
        return line
    }

    static func sentence(_ line: String, name: String) -> String {
        let n = name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? line + "." : "\(line), \(n)."
    }
}
