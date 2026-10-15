import AppIntents
import SwiftUI
import WidgetKit

/// Tile chrome shared by every widget: #0c0c0c with a #262626 edge, or a hint when Deck hasn't written yet.
struct Shell<V: View>: View {
    let entry: Entry
    let content: (WidgetSnapshot, WidgetFamily) -> V
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let s = entry.snapshot {
                content(s, family)
            } else {
                VStack(alignment: .leading) {
                    TileLabel(text: "Deck")
                    Spacer()
                    Text("Open Deck once to fill this in.").font(F.body).foregroundStyle(C.text2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(C.text)
        .containerBackground(for: .widget) {
            ZStack { C.tile; ContainerRelativeShape().stroke(C.border, lineWidth: 1) }
        }
    }
}

struct FocusView: View {
    let s: WidgetSnapshot
    let family: WidgetFamily

    var body: some View {
        if family == .systemMedium {
            HStack(alignment: .top, spacing: 16) {
                streak.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    TileLabel(text: "This week")
                    Spacer()
                    BigNumber(text: Stats.hours(s.focusMinutesThisWeek))
                    Text("focused").font(F.label).foregroundStyle(C.text2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                streak
                Text("\(Stats.hours(s.focusMinutesThisWeek)) this week").font(F.mono(11)).foregroundStyle(C.text2)
            }
        }
    }

    private var streak: some View {
        VStack(alignment: .leading, spacing: 4) {
            TileLabel(text: "Focus streak")
            Spacer()
            BigNumber(text: "\(s.streakDays)").foregroundStyle(s.streakDays > 0 ? C.lime : C.text)
            Text(s.streakDays == 1 ? "day" : "days").font(F.label).foregroundStyle(C.text2)
        }
    }
}

struct NextUpView: View {
    let s: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TileLabel(text: "Next up")
            Spacer()
            if let title = s.nextEventTitle, let start = s.nextEventStart {
                Text(title).font(F.ui(15, medium: true)).lineLimit(2)
                Text(when(start)).font(F.mono(12)).foregroundStyle(Color(hex: s.accentHex))
            } else {
                Text("Nothing coming up").font(F.body).foregroundStyle(C.text2)
            }
        }
    }

    private func when(_ d: Date) -> String {
        if d <= .now { return "now" }
        return Calendar.current.isDateInToday(d) ? clock(d) : "\(d.formatted(.dateTime.weekday(.abbreviated))) \(clock(d))"
    }
}

struct TasksView: View {
    let s: WidgetSnapshot
    let family: WidgetFamily

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TileLabel(text: "Today")
                Spacer()
                Text("\(s.tasks.filter { !$0.done }.count)").font(F.mono(11)).foregroundStyle(C.text2)
            }
            if s.tasks.isEmpty {
                Spacer()
                Text("Nothing due today").font(F.body).foregroundStyle(C.text2)
            }
            ForEach(s.tasks.prefix(family == .systemMedium ? 4 : 3)) { t in
                Button(intent: CompleteTaskIntent(id: t.id)) {
                    HStack(spacing: 8) {
                        Image(systemName: t.done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(t.done ? C.lime : C.text2)
                        Text(t.title).font(F.body).lineLimit(1).strikethrough(t.done)
                            .foregroundStyle(t.done ? C.text2 : C.text)
                        Spacer(minLength: 0)
                        if family == .systemMedium, let due = t.due {
                            Text(clock(due)).font(F.mono(11)).foregroundStyle(C.text2)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(t.done)
            }
            Spacer(minLength: 0)
        }
    }
}

struct DownloadView: View {
    let s: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TileLabel(text: "Downloading")
            Spacer()
            if let d = s.download {
                Text(d.name).font(F.body).lineLimit(2)
                Bar4(value: d.progress)
                Text("\(Int(d.progress * 100))%").font(F.mono(11)).foregroundStyle(C.text2)
            } else {
                Text("Nothing downloading").font(F.body).foregroundStyle(C.text2)
            }
        }
    }
}

struct MacStatusView: View {
    let s: WidgetSnapshot
    let family: WidgetFamily

    var body: some View {
        let accent = Color(hex: s.accentHex)
        let layout = family == .systemMedium ? AnyLayout(HStackLayout(alignment: .bottom, spacing: 16))
                                             : AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
        VStack(alignment: .leading, spacing: 8) {
            TileLabel(text: "Mac")
            Spacer(minLength: 0)
            layout {
                stat("CPU", "\(Int(s.cpu * 100))%", s.cpu, accent)
                stat("Memory", "\(Int(s.memory * 100))%", s.memory, accent)
                stat("Free", bytes(s.diskFree), nil, accent)
            }
        }
    }

    private func stat(_ label: String, _ value: String, _ fraction: Double?, _ accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(F.label).foregroundStyle(C.text2)
                Spacer(minLength: 4)
                Text(value).font(F.mono(11))
            }
            if let fraction { Bar4(value: fraction, color: accent) }
        }
        .frame(maxWidth: .infinity)
    }
}

struct SavedView: View {
    let s: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TileLabel(text: "Space saved")
            Spacer()
            BigNumber(text: bytes(s.savedBytes)).foregroundStyle(s.savedBytes > 0 ? C.lime : C.text)
                .minimumScaleFactor(0.6).lineLimit(1)
            Text(s.savedBytes > 0 ? "Made smaller or cleaned up" : "Try Files → Make smaller")
                .font(F.label).foregroundStyle(C.text2)
        }
    }
}
