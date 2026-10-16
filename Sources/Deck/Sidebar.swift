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
            .background(C.bg.ignoresSafeArea())
            .foregroundStyle(C.text)
            // No grey toolbar strip across the top: the black runs up to the window edge.
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
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

    /// Native sidebar column (so the traffic lights sit inside it), drawn in Deck's colours instead of grey and system blue.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Place.allCases) { p in
                SidebarRow(title: p.rawValue, icon: p.icon, selected: place == p) { place = p }
            }
            Spacer()
            SettingsLink {
                HStack(spacing: 10) {
                    Image(systemName: "gearshape").frame(width: 18)
                    Text("Settings").font(F.ui(13))
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .foregroundStyle(C.text2)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(C.bg)
        .toolbar(removing: .sidebarToggle)
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        .animation(.easeInOut(duration: 0.2), value: place)
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
/// A quiet line at the bottom: a short quote, new each time the window opens. A timer shows on the right only while something runs.
struct StatusLine: View {
    @ObservedObject private var downloads = Downloads.shared
    @ObservedObject private var focus = FocusTimer.shared
    /// Picked when the window opens, so every open gets a new one.
    @State private var line = Encouragement.next()

    var body: some View {
        HStack {
            Text(line).font(F.label)
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
    /// Short, student-minded lines for the bottom of the window. Written as proper sentences, no name.
    static let lines = [
        "Start before you feel ready.",
        "One chapter at a time.",
        "Done is better than perfect.",
        "Future you will thank you for this.",
        "Small steps still count.",
        "Twenty focused minutes beat two distracted hours.",
        "You don't have to be great to start, but you have to start to be great.",
        "Rest is part of the work.",
        "A little today beats a lot the night before.",
        "Progress, not perfection.",
        "The hardest part is opening the document.",
        "Ask for help early. It saves time later.",
        "Sleep is a study tool too.",
        "Every expert was once a beginner.",
        "Deadlines are closer than they look. Start now.",
        "Make today count.",
        "Breathe, then begin.",
        "You've done hard things before.",
    ]

    /// A different line from last time.
    static func next(defaults: UserDefaults = .standard) -> String {
        let last = defaults.string(forKey: "lastEncouragement")
        let line = lines.filter { $0 != last }.randomElement()!
        defaults.set(line, forKey: "lastEncouragement")
        return line
    }

}

private struct SidebarRow: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.accent) private var accent
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Capsule().fill(selected ? C.lime : .clear).frame(width: 3, height: 14)
                Image(systemName: icon).frame(width: 18)
                Text(title).font(F.ui(13, medium: selected))
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? accent.fill : (hover ? C.tile : .clear)))
            .foregroundStyle(selected ? accent.soft : C.text2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
