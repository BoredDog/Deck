import SwiftUI
import SwiftData

struct HomeView: View {
    @Query(sort: \FocusSession.start) private var sessions: [FocusSession]
    @Query(sort: \Activity.date, order: .reverse) private var activity: [Activity]
    @ObservedObject private var planner = Planner.shared
    @ObservedObject private var downloads = Downloads.shared
    @ObservedObject private var music = NowPlaying.shared
    @ObservedObject private var mac = SystemMonitor.shared
    @ObservedObject private var focus = FocusTimer.shared
    @ObservedObject private var setup = Setup.shared
    @AppStorage("place") private var place = Place.home
    @Environment(\.accent) private var accent

    private var pairs: [(Date, Int)] { sessions.map { ($0.start, $0.minutes) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            if Store.isMemoryOnly {
                Tile {
                    HStack(spacing: 8) {
                        Dot(color: C.warn)
                        Text("Deck couldn't open its saved data, so changes this session won't be kept. Restart Deck to try again.")
                            .font(F.body).foregroundStyle(C.text)
                    }
                }
                .frame(height: 56)
            }
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    streakTile.gridCellColumns(1)
                    focusWeekTile.gridCellColumns(2)
                    nextUpTile.gridCellColumns(1)
                }
                .frame(height: 170)
                GridRow {
                    tasksTile.gridCellColumns(2)
                    downloadsTile
                    savedTile
                }
                .frame(height: 170)
                GridRow {
                    heatmapTile.gridCellColumns(2)
                    macTile
                    musicTile
                }
                .frame(height: 170)
                GridRow {
                    activityTile.gridCellColumns(3)
                    WeatherTile()
                }
                .frame(minHeight: 200)
                if setup.showCard {
                    GridRow { SetupCard().gridCellColumns(4) }.frame(height: 130)
                }
            }
        }
        .task { await planner.refresh() }
        .onAppear { mac.startPolling() }
        .onDisappear { mac.stopPolling() }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 12) {
            Circle().fill(C.lime).frame(width: 36, height: 36)
                .overlay(Text(String(firstName.prefix(1))).font(F.ui(15, medium: true)).foregroundStyle(C.onLime))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(greeting), \(firstName)").font(F.ui(22, medium: true))
                Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide))).font(F.body).foregroundStyle(C.text2)
            }
            Spacer()
        }
    }

    private var firstName: String { NSFullUserName().split(separator: " ").first.map(String.init) ?? "there" }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        case 17..<22: "Good evening"
        default: "Hello"
        }
    }

    // MARK: tiles

    /// The single lime focal tile: the focus streak.
    private var streakTile: some View {
        let s = Stats.streak(days: sessions.map(\.start))
        return Tile(style: .lime) {
            TileLabel(text: "Focus streak", onLime: true)
            Spacer()
            BigNumber(text: "\(s) day\(s == 1 ? "" : "s")")
            Text(s == 0 ? "Start one today" : "Keep it going!").font(F.body).foregroundStyle(C.onLime.opacity(0.8))
        }
        .onTapGesture { place = .focus }
    }

    private var focusWeekTile: some View {
        let now = Stats.weekMinutes(pairs), last = Stats.weekMinutes(pairs, weeksAgo: 1)
        let days = Stats.minutesPerDay(pairs, count: 7)
        let best = days.max() ?? 0
        return Tile {
            TileLabel(text: "Focus time this week")
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    BigNumber(text: Stats.hours(now))
                    Text(compare(now, last)).font(F.body).foregroundStyle(C.text2)
                }
                Spacer()
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(Array(days.enumerated()), id: \.offset) { _, m in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(m > 0 && m == best ? C.lime : accent.accent.opacity(m > 0 ? 0.7 : 0.15))
                            .frame(width: 14, height: max(4, CGFloat(m) / CGFloat(max(best, 1)) * 70))
                    }
                }
            }
        }
    }

    private func compare(_ now: Int, _ last: Int) -> String {
        if now == 0 && last == 0 { return "Nothing yet. A short session counts." }
        if now > last { return "\(Stats.hours(now - last)) more than last week" }
        if now < last { return "\(Stats.hours(last - now)) to beat last week" }
        return "Same as last week"
    }

    private var nextUpTile: some View {
        Tile(style: .accent) {
            TileLabel(text: "Next up")
            Spacer()
            if let e = planner.nextEvent {
                Text(e.title).font(F.ui(15, medium: true)).foregroundStyle(accent.soft).lineLimit(2)
                Text(e.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())).font(F.mono(12)).foregroundStyle(accent.accent)
            } else {
                Text("Nothing on your calendar").font(F.body).foregroundStyle(accent.soft)
            }
        }
        .onTapGesture { place = .plan }
    }

    private var tasksTile: some View {
        Tile {
            TileLabel(text: "Today's tasks")
            if planner.todayTasks.isEmpty {
                Text("All clear for today.").font(F.body).foregroundStyle(C.text2)
            }
            ForEach(Array(planner.todayTasks.prefix(4).enumerated()), id: \.element.id) { i, t in
                Row(divider: i < min(planner.todayTasks.count, 4) - 1) {
                    Image(systemName: t.done ? "checkmark.circle.fill" : "circle").foregroundStyle(t.done ? C.lime : C.muted)
                    Text(t.title).font(F.body).foregroundStyle(t.done ? C.muted : C.text).lineLimit(1)
                    Spacer()
                    if let d = t.due { Text(clock(d)).font(F.mono(11)).foregroundStyle(C.text2) }
                }
            }
        }
        .onTapGesture { place = .plan }
    }

    private var downloadsTile: some View {
        let active = downloads.items.filter { $0.status == "active" || $0.status == "waiting" || $0.status == "paused" }
        return Tile {
            TileLabel(text: "Downloads")
            Spacer()
            if let d = active.first {
                Text(d.name).font(F.body).lineLimit(1).truncationMode(.middle)
                Bar4(value: d.progress)
                Text("\(Int(d.progress * 100))% · \(bytes(d.speed))/s").font(F.mono(11)).foregroundStyle(C.text2)
                if active.count > 1 { Text("+\(active.count - 1) more").font(F.label).foregroundStyle(C.text2) }
            } else {
                Text("Nothing downloading").font(F.body).foregroundStyle(C.text2)
            }
        }
        .onTapGesture { place = .downloads }
    }

    private var savedTile: some View {
        // Only "Make smaller" results; the originals stay until the user deletes them.
        let total = activity.filter { $0.kind == "convert" }.reduce(Int64(0)) { $0 + $1.savedBytes }
        return Tile {
            TileLabel(text: "Made smaller")
            Spacer()
            BigNumber(text: bytes(total)).foregroundStyle(total > 0 ? C.lime : C.text)
            Text(total > 0 ? "Delete the originals to free the space" : "Try Files → Make smaller").font(F.label).foregroundStyle(C.text2)
        }
        .onTapGesture { place = .files }
    }

    /// 12 weeks of focus, blending from the theme color into lime on strong days.
    private var heatmapTile: some View {
        let days = Stats.minutesPerDay(pairs, count: 84)
        return Tile {
            TileLabel(text: "Last 12 weeks")
            HStack(spacing: 3) {
                ForEach(0..<12, id: \.self) { w in
                    VStack(spacing: 3) {
                        ForEach(0..<7, id: \.self) { d in
                            RoundedRectangle(cornerRadius: 2).fill(heat(days[w * 7 + d])).frame(width: 12, height: 12)
                        }
                    }
                }
            }
        }
    }

    private func heat(_ m: Int) -> Color {
        switch m {
        case 0: C.line
        case ..<25: accent.accent.opacity(0.35)
        case ..<60: accent.accent.opacity(0.8)
        case ..<120: C.lime.opacity(0.6)
        default: C.lime
        }
    }

    private var macTile: some View {
        Tile {
            TileLabel(text: "Your Mac")
            Spacer()
            Text(mac.mood.prefix(1).uppercased() + mac.mood.dropFirst()).font(F.ui(14, medium: true)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            HStack { Text("CPU").font(F.label).foregroundStyle(C.text2).frame(width: 52, alignment: .leading); Bar4(value: mac.cpu, color: accent.accent) }
            HStack { Text("Memory").font(F.label).foregroundStyle(C.text2).frame(width: 52, alignment: .leading); Bar4(value: mac.memory, color: mac.memory > 0.85 ? C.warn : accent.accent) }
            if mac.diskTotal > 0 { Text("\(bytes(mac.diskFree)) free").font(F.mono(11)).foregroundStyle(C.text2) }
        }
        .onTapGesture { place = .mac }
    }

    private var musicTile: some View {
        Tile {
            TileLabel(text: music.app ?? "Music")
            Spacer()
            if let t = music.title {
                Text(t).font(F.body).lineLimit(1)
                Text(music.artist ?? "").font(F.label).foregroundStyle(C.text2).lineLimit(1)
                HStack(spacing: 6) {
                    Button { music.previous() } label: { Image(systemName: "backward.fill") }.buttonStyle(.pill)
                    Button { music.playPause() } label: { Image(systemName: music.isPlaying ? "pause.fill" : "play.fill") }.buttonStyle(.pill)
                    Button { music.next() } label: { Image(systemName: "forward.fill") }.buttonStyle(.pill)
                }
            } else {
                Text("Nothing playing").font(F.body).foregroundStyle(C.text2)
            }
        }
        .showsNowPlaying()
    }

    private var activityTile: some View {
        Tile {
            TileLabel(text: "Recent activity")
            if activity.isEmpty {
                Text("Things you do in Deck show up here.").font(F.body).foregroundStyle(C.text2)
            }
            ForEach(Array(activity.prefix(6).enumerated()), id: \.element.id) { i, a in
                Row(divider: i < min(activity.count, 6) - 1) {
                    Text(clock(a.date)).font(F.mono(11)).foregroundStyle(C.muted).frame(width: 44, alignment: .leading)
                    Text(a.text).font(F.body).lineLimit(1)
                    Spacer()
                    if a.savedBytes > 0 { Text("−\(bytes(a.savedBytes))").font(F.mono(11)).foregroundStyle(C.lime) }
                }
            }
        }
        .onTapGesture { place = .inbox }
    }
}
