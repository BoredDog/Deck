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
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(C.line).frame(width: 0.5)
            VStack(spacing: 0) {
                ScrollView {
                    detail.padding(24).frame(maxWidth: .infinity, alignment: .topLeading)
                }
                StatusLine()
            }
        }
        .background(C.bg)
        .foregroundStyle(C.text)
        .onAppear { MainWindow.opener = openWindow }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Spacer().frame(height: 36) // room for the window buttons
            ForEach(Place.allCases) { p in
                Button { place = p } label: {
                    HStack(spacing: 10) {
                        Image(systemName: p.icon).frame(width: 18)
                        Text(p.rawValue).font(F.ui(13, medium: place == p))
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(place == p ? accent.fill : .clear))
                    .foregroundStyle(place == p ? accent.soft : C.text2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
        .frame(width: 190)
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
struct StatusLine: View {
    @ObservedObject private var downloads = Downloads.shared
    @ObservedObject private var focus = FocusTimer.shared
    @State private var blink = true

    var body: some View {
        HStack {
            Text("● local · private").foregroundStyle(C.ok.opacity(0.7))
            Spacer()
            Text(summary)
            Rectangle().fill(C.muted).frame(width: 6, height: 11).opacity(blink ? 1 : 0)
        }
        .font(F.mono(11))
        .foregroundStyle(C.muted)
        .padding(.horizontal, 16).padding(.vertical, 6)
        .overlay(alignment: .top) { Rectangle().fill(C.line).frame(height: 0.5) }
        .onReceive(Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()) { _ in blink.toggle() }
    }

    private var summary: String {
        var parts: [String] = []
        if focus.running { parts.append("focus \(focus.remainingText)") }
        let active = downloads.items.filter { $0.status == "active" }.count
        if active > 0 { parts.append("\(active) downloading") }
        return parts.isEmpty ? "all quiet" : parts.joined(separator: " · ")
    }
}
