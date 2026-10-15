import SwiftUI
import SwiftData
import EventKit

struct PlanEvent: Identifiable, Equatable { let id: String; var title: String; var start: Date; var end: Date; var colorHex: UInt32? = nil }
struct PlanTask: Identifiable, Equatable { let id: String; var title: String; var due: Date?; var done: Bool; var hasTime = false }

/// Models this module stores with SwiftData; registered in Store.
enum PlanModels { static let all: [any PersistentModel.Type] = [Habit.self, WeekReview.self, JournalEntry.self] }

@Model final class Habit {
    var name: String
    var created: Date
    var days: [Date] = []   // start of each day it was done
    init(name: String) { self.name = name; self.created = .now }

    func done(on day: Date) -> Bool { days.contains { Calendar.current.isDate($0, inSameDayAs: day) } }
    /// Ticks or unticks any past day (or today). Future days are ignored.
    func toggle(_ day: Date = .now) {
        guard day <= .now else { return }
        if done(on: day) { days.removeAll { Calendar.current.isDate($0, inSameDayAs: day) } }
        else { days.append(Calendar.current.startOfDay(for: day)) }
    }
}

/// "Top 3 for next week", one record per week (keyed by the week's first day).
@Model final class WeekReview {
    var weekStart: Date
    var top: [String] = ["", "", ""]
    init(weekStart: Date) { self.weekStart = weekStart }
}

/// One line + mood per day. Both are sealed with Vault; only the day is stored in the clear.
@Model final class JournalEntry {
    var day: Date
    var sealed: Data
    init(day: Date, sealed: Data) { self.day = day; self.sealed = sealed }

    /// Nil when the entry can't be unlocked right now; then it is shown as locked and never overwritten.
    var content: (mood: Int, text: String)? {
        guard let s = Vault.openText(sealed) else { return nil }
        let parts = s.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        return (Int(parts.first ?? "") ?? 0, parts.count > 1 ? String(parts[1]) : "")
    }

    static func seal(mood: Int, text: String) -> Data? { try? Vault.seal("\(mood)\n\(text)") }
}

/// Reads "Lunch with Sam Friday 1pm" into a title and a date.
enum QuickAdd {
    private static let timeWords = try! NSRegularExpression(
        pattern: #"\d{1,2}(:\d{2})?\s*(am|pm|a\.m\.|p\.m\.)|\d{1,2}:\d{2}|\bnoon\b|\bmidnight\b|\bat \d{1,2}\b"#,
        options: .caseInsensitive)
    private static let fillers: Set<String> = ["at", "on", "by", "due", "for", "from", "this", "next"]

    /// Relative words ("tomorrow") resolve against the system clock (NSDataDetector has no public reference date);
    /// `now` is used to push a time that already passed today ("call mom at 5pm" said at 6pm) to tomorrow.
    static func parse(_ text: String, now: Date) -> (title: String, date: Date?, hasTime: Bool) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let m = det.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              var date = m.date, let r = Range(m.range, in: text) else { return (text, nil, false) }
        let phrase = String(text[r])
        let hasTime = timeWords.firstMatch(in: phrase, range: NSRange(phrase.startIndex..., in: phrase)) != nil
        let cal = Calendar.current
        if m.duration > 0 { date += m.duration }   // "due next Monday" comes back as a range ending on Monday
        if hasTime {
            if date < now, now.timeIntervalSince(date) < 86_400 { date = cal.date(byAdding: .day, value: 1, to: date)! }
        } else {
            date = cal.startOfDay(for: date)
        }
        var words = text.replacingCharacters(in: r, with: " ").split(separator: " ").map(String.init)
        while let w = words.last, fillers.contains(w.lowercased()) { words.removeLast() }
        while let w = words.first, fillers.contains(w.lowercased()) { words.removeFirst() }
        let title = words.joined(separator: " ")
        return (title.isEmpty ? text : title, date, hasTime)
    }
}

/// Day math shared by habits, focus streaks and heatmaps.
enum Days {
    /// Days in a row ending today (or yesterday, so an unfinished today doesn't break the streak).
    static func streak(_ dates: [Date], today: Date = .now, cal: Calendar = .current) -> Int {
        let set = Set(dates.map { cal.startOfDay(for: $0) })
        var day = cal.startOfDay(for: today)
        if !set.contains(day) { day = cal.date(byAdding: .day, value: -1, to: day)! }
        var n = 0
        while set.contains(day) { n += 1; day = cal.date(byAdding: .day, value: -1, to: day)! }
        return n
    }

    /// Counts per day as `weeks` columns of 7 days, oldest first; the last column is the current week.
    static func heatmap(_ dates: [Date], weeks: Int = 12, today: Date = .now, cal: Calendar = .current) -> [[Int]] {
        var grid = Array(repeating: Array(repeating: 0, count: 7), count: weeks)
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: today)!.start
        let first = cal.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek)!
        for d in dates {
            guard let i = cal.dateComponents([.day], from: first, to: cal.startOfDay(for: d)).day, i >= 0, i < weeks * 7 else { continue }
            grid[i / 7][i % 7] += 1
        }
        return grid
    }

    static var weekStart: Date { Calendar.current.dateInterval(of: .weekOfYear, for: .now)!.start }
}

@MainActor final class Planner: ObservableObject {
    static let shared = Planner()
    let store = EKEventStore()
    @Published var nextEvent: PlanEvent?
    @Published var todayTasks: [PlanTask] = []
    @Published var todayEvents: [PlanEvent] = []
    @Published var completedThisWeek = 0
    @Published var calendarAccess = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    @Published var reminderAccess = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    private var notified: Set<String> = []
    private var ticker: Timer?

    var askedBefore: Bool {
        EKEventStore.authorizationStatus(for: .event) != .notDetermined && EKEventStore.authorizationStatus(for: .reminder) != .notDetermined
    }
    /// True while a calendar event is happening (break reminders stay quiet).
    var inEvent: Bool { todayEvents.contains { $0.start <= .now && $0.end > .now } }

    private init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            Task { @MainActor in await Planner.shared.refresh() }
        }
        // Once a minute: refresh and announce events starting within 10 minutes and tasks coming due.
        ticker = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in await Planner.shared.refresh(); Planner.shared.announce() }
        }
    }

    /// Asks once; if the answer was already no, opens the right Privacy pane instead.
    func requestAccess() async {
        guard await Permission.explain(.calendar) else { return }
        let asked = askedBefore
        calendarAccess = (try? await store.requestFullAccessToEvents()) ?? false
        reminderAccess = (try? await store.requestFullAccessToReminders()) ?? false
        if asked && !(calendarAccess && reminderAccess) {
            let pane = calendarAccess ? "Privacy_Reminders" : "Privacy_Calendars"
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
        }
        await refresh()
    }

    func refresh() async {
        let cal = Calendar.current, now = Date.now
        let today = cal.startOfDay(for: now), tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        // Access may have been granted in System Settings since last time.
        calendarAccess = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        reminderAccess = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        if calendarAccess {
            let events = store.events(matching: store.predicateForEvents(withStart: today, end: cal.date(byAdding: .day, value: 8, to: today)!, calendars: nil))
                .filter { !$0.isAllDay }.sorted { $0.startDate < $1.startDate }.map(PlanEvent.init)
            todayEvents = events.filter { $0.start < tomorrow }
            nextEvent = events.first { $0.end > now }
        }
        if reminderAccess {
            let open = await reminders(store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil))
            todayTasks = open.filter { ($0.due ?? .distantPast) < tomorrow }
                .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            completedThisWeek = await reminders(store.predicateForCompletedReminders(withCompletionDateStarting: Days.weekStart, ending: now, calendars: nil)).count
        }
    }

    private func reminders(_ predicate: NSPredicate) async -> [PlanTask] {
        await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { list in
                cont.resume(returning: (list ?? []).map { r in
                    let c = r.dueDateComponents
                    return PlanTask(id: r.calendarItemIdentifier, title: r.title ?? "", due: c.flatMap { Calendar.current.date(from: $0) },
                                    done: r.isCompleted, hasTime: c?.hour != nil)
                })
            }
        }
    }

    private func announce() {
        let now = Date.now
        for e in todayEvents where e.start > now && e.start <= now + 600 && notified.insert("e\(e.id)\(e.start)").inserted {
            Store.log("\(e.title) starts at \(clock(e.start))", kind: "event", urgent: true)
        }
        // Only tasks that came due in the last 10 minutes, so a relaunch doesn't repeat old ones.
        for t in todayTasks where t.hasTime {
            guard let due = t.due, due <= now, due > now - 600, notified.insert("t\(t.id)").inserted else { continue }
            Store.log("\(t.title) is due now", kind: "task", urgent: true)
        }
    }

    // MARK: changes

    func addTask(_ title: String, due: Date? = nil, hasTime: Bool = false) {
        let r = EKReminder(eventStore: store)
        r.title = title
        r.calendar = store.defaultCalendarForNewReminders()
        if let due { r.dueDateComponents = dueComponents(due, hasTime: hasTime) }
        try? store.save(r, commit: true)
        Task { await refresh() }
    }

    func addEvent(_ title: String, start: Date, minutes: Int = 60) {
        let e = EKEvent(eventStore: store)
        e.title = title
        e.startDate = start
        e.endDate = start + Double(minutes * 60)
        e.calendar = store.defaultCalendarForNewEvents
        try? store.save(e, span: .thisEvent)
        Task { await refresh() }
    }

    /// "Type it like you'd say it": a time makes an event, a day makes a reminder due then, nothing makes a plain reminder.
    func quickAdd(_ text: String) {
        let p = QuickAdd.parse(text, now: .now)
        guard !p.title.isEmpty else { return }
        if let date = p.date, p.hasTime, calendarAccess { addEvent(p.title, start: date) }
        else { addTask(p.title, due: p.date, hasTime: p.hasTime) }
    }

    func complete(_ task: PlanTask) {
        guard let r = store.calendarItem(withIdentifier: task.id) as? EKReminder else { return }
        r.isCompleted = true
        try? store.save(r, commit: true)
        Task { await refresh() }
    }

    func setDue(_ task: PlanTask, _ date: Date?) {
        guard let r = store.calendarItem(withIdentifier: task.id) as? EKReminder else { return }
        r.dueDateComponents = date.map { dueComponents($0, hasTime: false) }
        try? store.save(r, commit: true)
        Task { await refresh() }
    }

    /// Dropping a task on the timeline blocks an hour for it.
    func block(taskID: String, at start: Date) {
        guard let t = todayTasks.first(where: { $0.id == taskID }) else { return }
        addEvent(t.title, start: start)
    }

    private func dueComponents(_ d: Date, hasTime: Bool) -> DateComponents {
        Calendar.current.dateComponents(hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day], from: d)
    }
}

private extension PlanEvent {
    init(_ e: EKEvent) {
        var hex: UInt32?
        if let c = e.calendar?.cgColor.flatMap({ NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }) {
            hex = UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255)
        }
        self.init(id: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? "", start: e.startDate, end: e.endDate, colorHex: hex)
    }
}
