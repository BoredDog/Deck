import Foundation
import Security
import SwiftData

// MARK: iCalendar reading

struct ICSEvent: Equatable {
    var uid = ""
    var summary = ""
    var description = ""
    var categories: [String] = []
    var start: Date?
    var end: Date?
    var allDay = false
}

/// A small reader for the .ics files Moodle exports: VEVENTs with UID, SUMMARY, DESCRIPTION, CATEGORIES, DTSTART, DTEND.
enum ICS {
    static func parse(_ text: String) -> [ICSEvent] {
        var events: [ICSEvent] = []
        var current: ICSEvent?
        for line in unfold(text) {
            guard let (name, params, value) = split(line) else { continue }
            switch name {
            case "BEGIN" where value.uppercased() == "VEVENT": current = ICSEvent()
            case "END" where value.uppercased() == "VEVENT":
                if let e = current { events.append(e) }
                current = nil
            case "UID": current?.uid = value
            case "SUMMARY": current?.summary = unescape(value).first ?? ""
            case "DESCRIPTION": current?.description = unescape(value).first ?? ""
            case "CATEGORIES": current?.categories += unescape(value, list: true).filter { !$0.isEmpty }
            case "DTSTART":
                if let (d, allDay) = date(value, params: params) { current?.start = d; current?.allDay = allDay }
            case "DTEND": current?.end = date(value, params: params)?.0
            default: break
            }
        }
        return events
    }

    /// Joins folded lines: a line break followed by a space or tab continues the previous line.
    static func unfold(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n ", with: "").replacingOccurrences(of: "\n\t", with: "")
            .split(separator: "\n").map(String.init)
    }

    /// `NAME;KEY=VAL;KEY="a:b":value` → ("NAME", [KEY: VAL], value). Colons inside quotes don't end the name.
    static func split(_ line: String) -> (String, [String: String], String)? {
        var quoted = false
        guard let colon = line.firstIndex(where: { c in
            if c == "\"" { quoted.toggle() }
            return c == ":" && !quoted
        }) else { return nil }
        let head = line[..<colon].split(separator: ";").map(String.init)
        guard let name = head.first?.uppercased() else { return nil }
        var params: [String: String] = [:]
        for p in head.dropFirst() {
            let kv = p.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { params[kv[0].uppercased()] = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        return (name, params, String(line[line.index(after: colon)...]))
    }

    /// Undoes `\n` `\,` `\;` `\\`. With `list`, unescaped commas split the value into parts.
    static func unescape(_ raw: String, list: Bool = false) -> [String] {
        var parts: [String] = [], cur = "", escaped = false
        for c in raw {
            if escaped {
                cur.append(c == "n" || c == "N" ? "\n" : c)
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "," && list {
                parts.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""
            } else {
                cur.append(c)
            }
        }
        parts.append(list ? cur.trimmingCharacters(in: .whitespaces) : cur)
        return parts
    }

    /// `20261020T235900Z` (UTC), `20261020T235900` with TZID (or local), `20261020` / VALUE=DATE (all day, local).
    static func date(_ value: String, params: [String: String]) -> (Date, Bool)? {
        let v = value.trimmingCharacters(in: .whitespaces)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        if params["VALUE"]?.uppercased() == "DATE" || v.count == 8 {
            f.dateFormat = "yyyyMMdd"
            f.timeZone = .current
            return f.date(from: String(v.prefix(8))).map { ($0, true) }
        }
        if v.hasSuffix("Z") {
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        } else {
            // Unknown zone names (Windows-style ones) fall back to the Mac's own zone.
            f.timeZone = params["TZID"].flatMap { TimeZone(identifier: $0) } ?? .current
            f.dateFormat = "yyyyMMdd'T'HHmmss"
        }
        return f.date(from: v).map { ($0, false) }
    }
}

// MARK: Moodle → Deadlines

enum Moodle {
    static let source = "moodle"

    /// The pasted link if it's https and looks like a Moodle calendar export.
    static func link(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: t), u.scheme?.lowercased() == "https", !(u.host ?? "").isEmpty else { return nil }
        let path = u.path.lowercased()
        return path.hasSuffix("export_execute.php") || path.hasSuffix(".ics") ? u : nil
    }

    /// One feed event as a deadline, or nil for "… opens" events and events without a UID or date.
    static func item(_ e: ICSEvent, cal: Calendar = .current) -> (uid: String, title: String, course: String, kind: DeadlineKind, due: Date)? {
        guard !e.uid.isEmpty, var due = e.start else { return nil }
        let summary = e.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = summary.lowercased()
        if lower.hasSuffix(" opens") || lower.hasSuffix("opens)") { return nil }
        var title = summary
        for pattern in [#"\s+(is due|closes|should be completed)$"#, #"\s*\([^()]*(closes|is due)\)$"#] {
            if let r = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                title = r.stringByReplacingMatches(in: title, range: NSRange(title.startIndex..., in: title), withTemplate: "")
            }
        }
        if title.isEmpty { title = summary }
        if e.allDay { due = cal.date(bySettingHour: 23, minute: 59, second: 0, of: due) ?? due }
        return (e.uid, title, e.categories.first ?? "", kind(summary: summary, description: e.description), due)
    }

    /// Quiz if the event mentions a quiz; exam, project or assignment from the words in its name.
    static func kind(summary: String, description: String) -> DeadlineKind {
        func words(_ s: String) -> Set<String> { Set(s.lowercased().components(separatedBy: CharacterSet.letters.inverted)) }
        let name = words(summary)
        if !name.isDisjoint(with: ["quiz", "quizzes"]) || words(description).contains("quiz") { return .quiz }
        if !name.isDisjoint(with: ["exam", "exams", "test", "midterm", "final", "finals"]) { return .exam }
        if name.contains("project") { return .project }
        return .assignment
    }

    /// Upserts feed events into the deadlines Deck imported before (matched by UID).
    /// Keeps "done", skips new events already past, and drops imported ones that left the feed if still ahead and not done.
    static func merge(_ events: [ICSEvent], into imported: [Deadline], now: Date) -> (added: [Deadline], removed: [Deadline]) {
        var byUID: [String: Deadline] = [:]
        for d in imported { if let uid = d.sourceUID { byUID[uid] = d } }
        var seen = Set<String>(), added: [Deadline] = []
        for e in events {
            guard let it = item(e), seen.insert(it.uid).inserted else { continue }
            if let d = byUID[it.uid] {
                (d.title, d.course, d.kind) = (it.title, it.course, it.kind.rawValue)
                if d.due != it.due { d.due = it.due; d.remindedDay = false; d.remindedHours = false }
            } else if it.due > now {
                let d = Deadline(title: it.title, course: it.course, due: it.due, kind: it.kind)
                (d.source, d.sourceUID) = (source, it.uid)
                added.append(d)
            }
        }
        let removed = imported.filter { d in
            guard let uid = d.sourceUID else { return false }
            return !seen.contains(uid) && d.due > now && !d.done
        }
        return (added, removed)
    }

    /// "just now", "12 min ago", "3 h ago", "Oct 14".
    static func ago(_ d: Date, now: Date) -> String {
        let mins = Int(now.timeIntervalSince(d) / 60)
        if mins < 1 { return "just now" }
        if mins < 60 { return "\(mins) min ago" }
        if mins < 24 * 60 { return "\(mins / 60) h ago" }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// The calendar link holds a private token, so it lives only in the Keychain.
enum MoodleLink {
    private static let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                              kSecAttrService as String: "com.nav.deck.moodle", kSecAttrAccount as String: "calendar-link"]

    static func load() -> URL? {
        var found: CFTypeRef?
        guard SecItemCopyMatching(item.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &found) == errSecSuccess,
              let data = found as? Data, let s = String(data: data, encoding: .utf8) else { return nil }
        return URL(string: s)
    }

    @discardableResult static func save(_ url: URL) -> Bool {
        delete()
        let add = item.merging([kSecValueData as String: Data(url.absoluteString.utf8),
                                kSecAttrLabel as String: "Deck Moodle calendar link",
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { $1 }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete() { SecItemDelete(item as CFDictionary) }
}

/// Fetches the user's own Moodle calendar: on connect, "Update now", soon after launch and every 3 hours.
@MainActor final class MoodleSync: ObservableObject {
    static let shared = MoodleSync()
    @Published private(set) var connected = MoodleLink.load() != nil
    @Published private(set) var updated = UserDefaults.standard.object(forKey: "moodleUpdated") as? Date
    @Published private(set) var busy = false
    @Published var problem: String?
    private var lastTry: Date?
    private static let session = URLSession(configuration: .ephemeral)   // no cookies, no cache on disk

    static let unreachable = "Couldn't reach Moodle. Deck will try again later."
    static let badLink = "That link didn't work. Make a new one in Moodle and paste it again."

    private enum Outcome { case events([ICSEvent]), unreachable, badLink }

    /// Saves the link and imports. A link Moodle rejects isn't saved; one that can't be reached yet is.
    func connect(_ text: String) async {
        guard let url = Moodle.link(text) else {
            problem = "Paste the link from Moodle's Get calendar URL button. It starts with https://"
            return
        }
        busy = true
        defer { busy = false }
        let outcome = await fetch(url)
        if case .badLink = outcome { problem = Self.badLink; return }
        guard MoodleLink.save(url) else { problem = "Deck couldn't save the link in your Keychain."; return }
        connected = true
        handle(outcome)
    }

    func update() async {
        guard !busy, let url = MoodleLink.load() else { return }
        busy = true
        defer { busy = false }
        handle(await fetch(url))
    }

    /// Called each minute by `Deadlines.announce`. Retries after 15 minutes when the last try failed.
    func syncIfDue(now: Date = .now) {
        guard connected, !busy else { return }
        if let lastTry, now.timeIntervalSince(lastTry) < (problem == nil ? 3 * 3600 : 15 * 60) { return }
        Task { await update() }
    }

    func disconnect(removeImported: Bool) {
        MoodleLink.delete()
        (connected, updated, problem, lastTry) = (false, nil, nil, nil)
        UserDefaults.standard.removeObject(forKey: "moodleUpdated")
        guard removeImported else { return }
        for d in Self.imported() { Store.context.delete(d) }
        try? Store.context.save()
    }

    private static func imported() -> [Deadline] {
        ((try? Store.context.fetch(FetchDescriptor<Deadline>())) ?? []).filter { $0.source == Moodle.source }
    }

    private func fetch(_ url: URL) async -> Outcome {
        lastTry = .now
        do {
            let (data, response) = try await Self.session.data(for: URLRequest(url: url, timeoutInterval: 30))
            let code = (response as? HTTPURLResponse)?.statusCode ?? 200
            if code >= 500 { return .unreachable }
            // A bad or expired token gets an error page, not a calendar.
            guard code < 400, let text = String(data: data, encoding: .utf8), text.contains("BEGIN:VCALENDAR") else { return .badLink }
            return .events(ICS.parse(text))
        } catch {
            return .unreachable
        }
    }

    private func handle(_ outcome: Outcome) {
        switch outcome {
        case .unreachable: problem = Self.unreachable
        case .badLink: problem = Self.badLink
        case .events(let events):
            let now = Date.now
            let (added, removed) = Moodle.merge(events, into: Self.imported(), now: now)
            added.forEach(Store.context.insert)
            removed.forEach(Store.context.delete)
            try? Store.context.save()
            (updated, problem) = (now, nil)
            UserDefaults.standard.set(now, forKey: "moodleUpdated")
        }
    }
}
