import SwiftUI
import SwiftData

struct PlanView: View {
    @ObservedObject private var planner = Planner.shared
    @State private var quick = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ScreenHeader(title: "Plan", subtitle: "Your day, your tasks, and a moment to look back.")
            if !(planner.calendarAccess && planner.reminderAccess) { accessTile }
            quickAdd
            // Two equal halves; a Grid let wide text fields stretch one column past the window edge.
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    TimelineTile().frame(maxWidth: .infinity)
                    TasksTile().frame(maxWidth: .infinity)
                }
                .frame(height: 440)
                HStack(spacing: 8) {
                    HabitsTile().frame(maxWidth: .infinity)
                    WeekReviewTile().frame(maxWidth: .infinity)
                }
                .frame(minHeight: 300)
                JournalTile()
            }
        }
        .task {
            // First visit: the system asks right away, with the sentence below on screen.
            if planner.askedBefore { await planner.refresh() } else { await planner.requestAccess() }
        }
    }

    private var accessTile: some View {
        Tile(style: .accent) {
            Text("Deck can show your calendars and reminders here. They never leave this Mac.").font(F.body)
            Button(planner.askedBefore ? "Open Settings to allow" : "Show my calendar") { Task { await planner.requestAccess() } }
                .buttonStyle(.primary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var quickAdd: some View {
        Tile {
            TileLabel(text: "Type it like you'd say it")
            HStack(spacing: 8) {
                TextField("Lunch with Sam Friday 1pm", text: $quick)
                    .textFieldStyle(.plain).font(F.ui(15))
                    .onSubmit(add)
                if planner.calendarAccess {
                    Button("Add", action: add).buttonStyle(.primary).disabled(quick.isEmpty)
                } else {
                    Button("Add", action: add).buttonStyle(.pill).disabled(quick.isEmpty)
                }
            }
            HStack(spacing: 10) {
                Button("Add Google or Outlook") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!)
                }
                .buttonStyle(.pill)
                Text("Add the account in Internet Accounts and turn on Calendars and Reminders.").font(F.label).foregroundStyle(C.text2)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func add() {
        guard !quick.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        planner.quickAdd(quick)
        quick = ""
    }
}

// MARK: today

private struct TimelineTile: View {
    @ObservedObject private var planner = Planner.shared
    @Environment(\.accent) private var accent
    @State private var target: Int?
    private let hours = 7..<24
    private let rowH: CGFloat = 40

    var body: some View {
        Tile {
            TileLabel(text: "Today")
            ScrollView {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) { ForEach(hours, id: \.self, content: slot) }
                    ForEach(planner.todayEvents.filter { y($0.end) > 0 }) { e in block(e) }
                    nowLine
                }
            }
        }
    }

    private func slot(_ h: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(String(format: "%02d:00", h)).font(F.mono(10)).foregroundStyle(C.muted).frame(width: 40, alignment: .leading)
            VStack(spacing: 0) {
                Rectangle().fill(C.line).frame(height: 0.5)
                Rectangle().fill(target == h ? accent.fill : .clear)
            }
        }
        .frame(height: rowH)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, let start = Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: .now) else { return false }
            planner.block(taskID: id, at: start)
            return true
        } isTargeted: { target = $0 ? h : (target == h ? nil : target) }
    }

    private func y(_ d: Date) -> CGFloat {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return max(0, (CGFloat(c.hour ?? 0) - CGFloat(hours.lowerBound) + CGFloat(c.minute ?? 0) / 60) * rowH)
    }

    private func block(_ e: PlanEvent) -> some View {
        let color = e.colorHex.map { Color(hex: $0) } ?? accent.accent
        let top = y(e.start)
        return HStack(spacing: 6) {
            Rectangle().fill(color).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.title).font(F.ui(12, medium: true)).lineLimit(1)
                Text("\(clock(e.start))–\(clock(e.end))").font(F.mono(10)).foregroundStyle(C.text2)
            }
            Spacer(minLength: 0)
        }
        .frame(height: max(20, y(e.end) - top), alignment: .top)
        .background(color.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(.leading, 48)
        .offset(y: top)
    }

    @ViewBuilder private var nowLine: some View {
        let h = Calendar.current.component(.hour, from: .now)
        if hours.contains(h) {
            Rectangle().fill(accent.accent).frame(height: 1).padding(.leading, 48).offset(y: y(.now))
        }
    }
}

private struct TasksTile: View {
    @ObservedObject private var planner = Planner.shared
    @State private var ticked: Set<String> = []

    var body: some View {
        Tile {
            TileLabel(text: "Tasks")
            if !planner.reminderAccess {
                Text("Allow reminders to see your tasks here.").font(F.body).foregroundStyle(C.text2)
            } else if planner.todayTasks.isEmpty {
                Text("Nothing due today. Nice.").font(F.body).foregroundStyle(C.text2)
            } else {
                Text("Drag a task onto your day to make time for it.").font(F.label).foregroundStyle(C.muted)
                ScrollView {
                    VStack(spacing: 0) { ForEach(planner.todayTasks, content: row) }
                }
            }
        }
    }

    private func row(_ t: PlanTask) -> some View {
        Row {
            Button {
                ticked.insert(t.id)
                // Let the check show for a moment before the task leaves the list.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { planner.complete(t) }
            } label: {
                Image(systemName: ticked.contains(t.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(ticked.contains(t.id) ? C.lime : C.muted)
            }
            .buttonStyle(.plain)
            Text(t.title).font(F.body).lineLimit(1)
            Spacer()
            Menu {
                Button("Today") { planner.setDue(t, .now) }
                Button("Tomorrow") { planner.setDue(t, Calendar.current.date(byAdding: .day, value: 1, to: .now)) }
                Button("Next week") { planner.setDue(t, Calendar.current.date(byAdding: .day, value: 7, to: .now)) }
                Button("No date") { planner.setDue(t, nil) }
            } label: {
                Text(dueText(t)).font(F.mono(11)).foregroundStyle(isLate(t) ? C.warn : C.text2)
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .draggable(t.id)
    }

    private func isLate(_ t: PlanTask) -> Bool { (t.due ?? .distantFuture) < Calendar.current.startOfDay(for: .now) }

    private func dueText(_ t: PlanTask) -> String {
        guard let d = t.due else { return "no date" }
        if isLate(t) { return "late" }
        return t.hasTime ? clock(d) : "today"
    }
}

// MARK: habits

private struct HabitsTile: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Habit.created) private var habits: [Habit]
    @State private var name = ""

    var body: some View {
        Tile {
            TileLabel(text: "Habits")
            ForEach(habits) { h in
                Row {
                    Button { h.toggle(); try? context.save() } label: {
                        Image(systemName: h.done(on: .now) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(h.done(on: .now) ? C.lime : C.muted)
                    }
                    .buttonStyle(.plain)
                    Text(h.name).font(F.body)
                    Spacer()
                    pastDays(h)
                    let s = Days.streak(h.days)
                    Text(s == 1 ? "1 day" : "\(s) days").font(F.mono(11)).foregroundStyle(s > 0 ? C.lime : C.muted)
                }
                .contextMenu { Button("Remove") { context.delete(h); try? context.save() } }
            }
            TextField("Add a habit, like Read 10 pages", text: $name)
                .textFieldStyle(.plain).font(F.body)
                .onSubmit {
                    guard !name.isEmpty else { return }
                    context.insert(Habit(name: name)); try? context.save(); name = ""
                }
            Spacer(minLength: 4)
            HabitHeatmap()
        }
    }

    /// The six days before today, oldest first. Tap one to tick a day you forgot.
    private func pastDays(_ h: Habit) -> some View {
        HStack(spacing: 4) {
            ForEach((1...6).reversed(), id: \.self) { back in
                let day = Calendar.current.date(byAdding: .day, value: -back, to: .now)!
                Button { h.toggle(day); try? context.save() } label: {
                    Circle().fill(h.done(on: day) ? C.lime : C.line).frame(width: 8, height: 8)
                }
                .buttonStyle(.plain)
                .help(day.formatted(.dateTime.weekday(.wide).month().day()))
                .accessibilityLabel("\(h.name), \(day.formatted(.dateTime.weekday(.wide))), \(h.done(on: day) ? "done" : "not done")")
            }
        }
    }
}

/// Last 12 weeks of habits. Stronger days blend from the theme accent to lime. Home can drop this in as is.
struct HabitHeatmap: View {
    @Query private var habits: [Habit]
    @Environment(\.accent) private var accent
    var weeks = 12

    var body: some View {
        let grid = Days.heatmap(habits.flatMap(\.days), weeks: weeks)
        let todayIndex = (weeks - 1) * 7 + (Calendar.current.dateComponents([.day], from: Days.weekStart, to: Calendar.current.startOfDay(for: .now)).day ?? 0)
        HStack(spacing: 3) {
            ForEach(0..<weeks, id: \.self) { w in
                VStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { d in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(w * 7 + d > todayIndex ? Color.clear : color(grid[w][d]))
                            .frame(width: 11, height: 11)
                    }
                }
            }
        }
    }

    private func color(_ count: Int) -> Color {
        guard count > 0, !habits.isEmpty else { return C.line }
        let f = Double(count) / Double(habits.count)
        return f >= 1 ? C.lime : accent.accent.opacity(0.3 + 0.5 * f)
    }
}

// MARK: weekly review

private struct WeekReviewTile: View {
    @Environment(\.modelContext) private var context
    @ObservedObject private var planner = Planner.shared
    @Query private var sessions: [FocusSession]
    @Query private var habits: [Habit]
    @Query private var reviews: [WeekReview]

    private var weekStart: Date { Days.weekStart }

    var body: some View {
        Tile(style: .accent) {
            TileLabel(text: "This week")
            stat("Focus time", String(format: "%.1f h", Double(sessions.filter { $0.start >= weekStart }.map(\.minutes).reduce(0, +)) / 60))
            stat("Tasks done", "\(planner.completedThisWeek)")
            stat("Space saved", bytes(savedThisWeek))
            stat("Habits kept", habitsKept)
            TileLabel(text: "Top 3 for next week").padding(.top, 6)
            if let review = reviews.first(where: { $0.weekStart == weekStart }) {
                ForEach(0..<3, id: \.self) { i in
                    TextField("\(i + 1).", text: Binding(get: { review.top[i] }, set: { review.top[i] = $0; try? context.save() }))
                        .textFieldStyle(.plain).font(F.body)
                }
            }
        }
        .task {
            if !reviews.contains(where: { $0.weekStart == weekStart }) { context.insert(WeekReview(weekStart: weekStart)) }
        }
    }

    private func stat(_ name: String, _ value: String) -> some View {
        Row {
            Text(name).font(F.body)
            Spacer()
            Text(value).font(F.mono(12)).foregroundStyle(C.text2)
        }
    }

    private var savedThisWeek: Int64 {
        let start = weekStart
        let items = (try? context.fetch(FetchDescriptor<Activity>(predicate: #Predicate { $0.date >= start && $0.savedBytes > 0 }))) ?? []
        return items.map(\.savedBytes).reduce(0, +)
    }

    private var habitsKept: String {
        let daysSoFar = (Calendar.current.dateComponents([.day], from: weekStart, to: .now).day ?? 0) + 1
        let kept = habits.flatMap(\.days).filter { $0 >= weekStart }.count
        return "\(kept) of \(habits.count * daysSoFar)"
    }
}

// MARK: journal

private struct JournalTile: View {
    @Environment(\.modelContext) private var context
    @Environment(\.accent) private var accent
    @Query(sort: \JournalEntry.day, order: .reverse) private var entries: [JournalEntry]
    @State private var line = ""
    @State private var mood = 0
    @State private var loaded = false
    @State private var locked = false       // today's entry can't be unlocked: never overwrite it
    @State private var edited = false
    @State private var saveTask: Task<Void, Never>?

    private var today: Date { Calendar.current.startOfDay(for: .now) }

    var body: some View {
        Tile {
            HStack {
                TileLabel(text: "One line about today")
                Spacer()
                Text("Private, encrypted on this Mac").font(F.label).foregroundStyle(C.muted)
            }
            if locked {
                Text(Self.lockedText).font(F.body).foregroundStyle(C.text2)
            } else {
                HStack(spacing: 10) {
                    TextField("What stood out?", text: Binding(get: { line }, set: { line = $0; changed() }))
                        .textFieldStyle(.plain).font(F.ui(14)).onSubmit(save)
                    dots(mood) { mood = $0; changed() }
                    Button("Save", action: save).buttonStyle(.pill).disabled(line.isEmpty && mood == 0)
                }
            }
            ForEach(entries.prefix(6).filter { $0.day != today }) { e in
                let c = e.content
                Row {
                    Text(e.day.formatted(.dateTime.month(.abbreviated).day())).font(F.mono(11)).foregroundStyle(C.muted).frame(width: 52, alignment: .leading)
                    if let c {
                        dots(c.mood, small: true) { _ in }
                        Text(c.text).font(F.body).foregroundStyle(C.text2).lineLimit(1)
                    } else {
                        Text(Self.lockedText).font(F.body).foregroundStyle(C.text2).lineLimit(1)
                    }
                    Spacer()
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            guard !loaded, let e = entries.first(where: { $0.day == today }) else { return }
            if let c = e.content { (mood, line) = c } else { locked = true }
            loaded = true
        }
        .onDisappear(perform: save)
    }

    /// Five small dots; the mood is how many are filled.
    private func dots(_ value: Int, small: Bool = false, pick: @escaping (Int) -> Void) -> some View {
        HStack(spacing: small ? 3 : 5) {
            ForEach(1...5, id: \.self) { i in
                Circle().fill(i <= value ? accent.accent : C.line)
                    .frame(width: small ? 6 : 10, height: small ? 6 : 10)
                    .onTapGesture { pick(i) }
            }
        }
        .accessibilityLabel("Mood \(value) of 5")
    }

    private static let lockedText = "This private entry can't be opened right now."

    /// Saves after 1 second without typing.
    private func changed() {
        edited = true
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { save() }
        }
    }

    /// Only saves what you typed, and never over an entry that can't be unlocked.
    private func save() {
        saveTask?.cancel()
        let existing = entries.first(where: { $0.day == today })
        guard edited, !locked, existing.map({ $0.content != nil }) ?? true,
              let sealed = JournalEntry.seal(mood: mood, text: line) else { return }
        if let existing { existing.sealed = sealed }
        else { context.insert(JournalEntry(day: today, sealed: sealed)) }
        try? context.save()
        edited = false
    }
}
