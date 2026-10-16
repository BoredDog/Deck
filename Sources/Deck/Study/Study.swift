import Foundation
import SwiftData

// MARK: deadlines & exams

enum DeadlineKind: String, CaseIterable {
    case assignment, exam, quiz, project
    var label: String { rawValue.capitalized }

    /// Words that name a kind, so "Physics exam Friday 9am" becomes an exam.
    static func from(word: String) -> DeadlineKind? {
        switch word.lowercased().trimmingCharacters(in: .punctuationCharacters) {
        case "exam", "exams", "midterm", "final", "finals", "test": .exam
        case "quiz": .quiz
        case "project": .project
        case "assignment", "homework", "hw", "essay", "lab", "report", "pset", "worksheet": .assignment
        default: nil
        }
    }
}

@Model final class Deadline {
    var title: String
    var course: String = ""
    var due: Date
    var kind: String = DeadlineKind.assignment.rawValue
    var done: Bool = false
    // Which reminders were already sent; cleared when the due time changes.
    var remindedDay: Bool = false
    var remindedHours: Bool = false

    init(title: String, course: String = "", due: Date, kind: DeadlineKind = .assignment) {
        self.title = title
        self.course = course
        self.due = due
        self.kind = kind.rawValue
    }

    var deadlineKind: DeadlineKind { DeadlineKind(rawValue: kind) ?? .assignment }
}

enum DeadlineReminder: Equatable { case dayBefore, twoHours }

enum Deadlines {
    /// "Physics exam Friday 9am" → title "Physics exam", course "Physics", exam, Friday 09:00.
    /// A day without a time means the end of that day. Nil when there's no day in the text.
    static func parse(_ text: String, now: Date, cal: Calendar = .current) -> (title: String, course: String, kind: DeadlineKind, due: Date)? {
        let p = QuickAdd.parse(text, now: now)
        guard var due = p.date, !p.title.isEmpty else { return nil }
        if !p.hasTime { due = cal.date(bySettingHour: 23, minute: 59, second: 0, of: due) ?? due }
        let words = p.title.split(separator: " ").map(String.init)
        guard let i = words.firstIndex(where: { DeadlineKind.from(word: $0) != nil }) else { return (p.title, "", .assignment, due) }
        return (p.title, words[..<i].joined(separator: " "), DeadlineKind.from(word: words[i])!, due)
    }

    /// Big countdown numbers: days and hours when a day or more is left, otherwise hours and minutes.
    static func countdown(to due: Date, now: Date) -> [(value: String, unit: String)] {
        let mins = max(0, Int(due.timeIntervalSince(now)) / 60)
        func two(_ n: Int) -> String { String(format: "%02d", n) }
        if mins >= 24 * 60 {
            let d = mins / 1440, h = mins % 1440 / 60
            return [(two(d), d == 1 ? "DAY" : "DAYS"), (two(h), h == 1 ? "HR" : "HRS")]
        }
        let h = mins / 60
        return [(two(h), h == 1 ? "HR" : "HRS"), (two(mins % 60), "MIN")]
    }

    static func countdownText(to due: Date, now: Date) -> String {
        countdown(to: due, now: now).map { "\($0.value) \($0.unit)" }.joined(separator: " ")
    }

    /// The reminder to send now, if any: one a day before and one 2 hours before, each once.
    /// Inside the 2-hour window only that one is sent (the day-before one would be stale).
    static func reminder(due: Date, now: Date, sentDay: Bool, sentHours: Bool) -> DeadlineReminder? {
        let left = due.timeIntervalSince(now)
        guard left > 0 else { return nil }
        if left <= 2 * 3600 { return sentHours ? nil : .twoHours }
        if left <= 24 * 3600 { return sentDay ? nil : .dayBefore }
        return nil
    }

    /// Called once a minute by Planner's ticker.
    @MainActor static func announce(now: Date = .now) {
        let open = (try? Store.context.fetch(FetchDescriptor<Deadline>(predicate: #Predicate { !$0.done }))) ?? []
        var changed = false
        for d in open {
            guard let r = reminder(due: d.due, now: now, sentDay: d.remindedDay, sentHours: d.remindedHours) else { continue }
            d.remindedDay = true
            if r == .twoHours { d.remindedHours = true }
            changed = true
            let when = d.due.formatted(.dateTime.weekday(.abbreviated)) + " " + clock(d.due)
            Store.log(r == .twoHours ? "2 hours left: \(d.title), \(clock(d.due))" : "1 day left: \(d.title), \(when)", kind: "task", urgent: true)
        }
        if changed { try? Store.context.save() }
    }
}

// MARK: class timetable

@Model final class ClassSlot {
    var course: String
    var weekday: Int        // Calendar weekday: 1 = Sunday … 7 = Saturday
    var start: Int          // minutes after midnight
    var end: Int
    var room: String = ""
    var color: Int = 0      // index into Accent.all

    init(course: String, weekday: Int, start: Int, end: Int, room: String = "", color: Int = 0) {
        self.course = course
        self.weekday = weekday
        self.start = start
        self.end = end
        self.room = room
        self.color = color
    }
}

enum Timetable {
    /// Calendar weekdays, Monday first.
    static let week = [2, 3, 4, 5, 6, 7, 1]

    /// The next class to start at or after `now`, looking across the week boundary.
    static func nextClass(in classes: [ClassSlot], now: Date, cal: Calendar = .current) -> (title: String, start: Date, room: String?)? {
        classes.compactMap { c -> (ClassSlot, Date)? in
            let match = DateComponents(hour: c.start / 60, minute: c.start % 60, weekday: c.weekday)
            return cal.nextDate(after: now - 1, matching: match, matchingPolicy: .nextTime).map { (c, $0) }
        }
        .min { $0.1 < $1.1 }
        .map { ($0.0.course, $0.1, $0.0.room.isEmpty ? nil : $0.0.room) }
    }

    /// For Home and the menu bar.
    @MainActor static func nextClass(now: Date = .now) -> (title: String, start: Date, room: String?)? {
        nextClass(in: (try? Store.context.fetch(FetchDescriptor<ClassSlot>())) ?? [], now: now)
    }

    /// "in 12 min", "at 14:00" later today, "Tue 09:00" on another day.
    static func when(_ start: Date, now: Date, cal: Calendar = .current) -> String {
        let mins = Int(start.timeIntervalSince(now) / 60)
        if mins < 1 { return "now" }
        if mins < 60 { return "in \(mins) min" }
        if cal.isDate(start, inSameDayAs: now) { return "at \(clock(start))" }
        return start.formatted(.dateTime.weekday(.abbreviated)) + " " + clock(start)
    }

    /// "9", "9:30", "14:00", "2pm", "2:30 pm" → minutes after midnight.
    static func minutes(_ text: String) -> Int? {
        var t = text.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ".", with: ":")
        let pm = t.hasSuffix("pm"), am = t.hasSuffix("am")
        if pm || am { t.removeLast(2) }
        let parts = t.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), var h = Int(parts[0]),
              let m = parts.count == 2 ? Int(parts[1]) : 0, (0..<60).contains(m) else { return nil }
        if pm || am {
            guard (1...12).contains(h) else { return nil }
            h = h % 12 + (pm ? 12 : 0)
        }
        guard (0..<24).contains(h) else { return nil }
        return h * 60 + m
    }

    static func time(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
}

// MARK: focus by subject

enum Subjects {
    static let none = "No subject"

    /// Minutes per subject, most first. Sessions without a subject count as "No subject".
    static func minutes(_ sessions: [(subject: String?, minutes: Int)]) -> [(name: String, minutes: Int)] {
        var sums: [String: Int] = [:]
        for s in sessions {
            let name = s.subject?.trimmingCharacters(in: .whitespaces) ?? ""
            sums[name.isEmpty ? none : name, default: 0] += s.minutes
        }
        return sums.map { ($0.key, $0.value) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
    }

    /// Course names from the timetable, deadlines and ones typed in Focus: trimmed, no repeats, A–Z.
    static func list(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
