import Foundation

/// Small pure helpers behind the Home tiles (tested in DeckTests).
enum Stats {
    /// Days in a row (ending today, or yesterday if today has nothing yet) that have at least one entry.
    static func streak(days: [Date], now: Date = .now, cal: Calendar = .current) -> Int {
        let set = Set(days.map { cal.startOfDay(for: $0) })
        var day = cal.startOfDay(for: now)
        if !set.contains(day) { day = cal.date(byAdding: .day, value: -1, to: day)! }
        var n = 0
        while set.contains(day) {
            n += 1
            day = cal.date(byAdding: .day, value: -1, to: day)!
        }
        return n
    }

    /// Minutes per day for the last `count` days, oldest first.
    static func minutesPerDay(_ sessions: [(Date, Int)], count: Int, now: Date = .now, cal: Calendar = .current) -> [Int] {
        let today = cal.startOfDay(for: now)
        var out = Array(repeating: 0, count: count)
        for (d, m) in sessions {
            let diff = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: today).day ?? -1
            if diff >= 0 && diff < count { out[count - 1 - diff] += m }
        }
        return out
    }

    static func weekMinutes(_ sessions: [(Date, Int)], weeksAgo: Int = 0, now: Date = .now, cal: Calendar = .current) -> Int {
        guard let thisWeek = cal.dateInterval(of: .weekOfYear, for: now),
              let start = cal.date(byAdding: .weekOfYear, value: -weeksAgo, to: thisWeek.start),
              let end = cal.date(byAdding: .weekOfYear, value: 1, to: start) else { return 0 }
        return sessions.filter { $0.0 >= start && $0.0 < end }.reduce(0) { $0 + $1.1 }
    }

    static func hours(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes)m" : minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }
}
