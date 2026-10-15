import SwiftUI
import SwiftData
import Combine
import UserNotifications

enum InboxModels { static let all: [any PersistentModel.Type] = [] }

/// Called for every new Activity. Shows a system notification, or holds it during a focus session unless urgent.
@MainActor enum Inbox {
    private static var held: [String] = []   // kinds of activities held back during focus
    private static var watch: AnyCancellable?
    private static var asked = false

    static func deliver(_ a: Activity) {
        startWatching()
        if FocusTimer.shared.running && !a.urgent { held.append(a.kind); return }
        notify(a.text, file: a.fileURL)
    }

    /// Call once at launch so banners show while Deck is in front and clicks open the right thing.
    static func start() {
        guard Bundle.main.bundleIdentifier != nil else { return } // notifications need a real app bundle
        UNUserNotificationCenter.current().delegate = InboxNotifications.shared
    }

    /// "While you focused: 3 downloads finished, 1 file converted"
    nonisolated static func summary(kinds: [String]) -> String {
        let names: [String: (String, String)] = [
            "download": ("download finished", "downloads finished"), "convert": ("file converted", "files converted"),
            "event": ("event", "events"), "task": ("task due", "tasks due"), "focus": ("focus update", "focus updates"),
            "break": ("break reminder", "break reminders"), "info": ("update", "updates"),
        ]
        var order: [String] = [], counts: [String: Int] = [:]
        for k in kinds { if counts[k] == nil { order.append(k) }; counts[k, default: 0] += 1 }
        let parts = order.map { k -> String in
            let n = counts[k]!, name = names[k] ?? names["info"]!
            return "\(n) \(n == 1 ? name.0 : name.1)"
        }
        return "While you focused: " + parts.joined(separator: ", ")
    }

    private static func startWatching() {
        guard watch == nil else { return }
        watch = FocusTimer.shared.$running.removeDuplicates().dropFirst().sink { running in
            guard !running, !held.isEmpty else { return }
            let text = summary(kinds: held)
            held = []
            notify(text)
        }
    }

    private static func notify(_ text: String, file: String? = nil) {
        guard Bundle.main.bundleIdentifier != nil else { return } // notifications need a real app bundle
        let center = UNUserNotificationCenter.current()
        if center.delegate == nil { center.delegate = InboxNotifications.shared }
        Task {
            if !asked { asked = true; _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
            let content = UNMutableNotificationContent()
            content.title = "Deck"
            content.body = text
            if let file { content.userInfo = ["file": file] }
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    static let kindNames: [String: String] = ["download": "Downloads", "convert": "Files", "event": "Events", "task": "Tasks",
                                              "focus": "Focus", "break": "Breaks", "info": "Other"]
}

/// Shows banners even while Deck is the front app. Clicking one opens its file, or the Inbox.
final class InboxNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = InboxNotifications()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let path = response.notification.request.content.userInfo["file"] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let path, FileManager.default.fileExists(atPath: path) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                } else {
                    UserDefaults.standard.set(Place.inbox.rawValue, forKey: "place")
                    MainWindow.open()
                }
            }
            done()
        }
    }
}

struct InboxView: View {
    @Query(sort: \Activity.date, order: .reverse) private var all: [Activity]
    @Environment(\.modelContext) private var context
    @Environment(\.accent) private var accent
    @State private var kind: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { t in
            let shown = all.filter { ($0.snoozedUntil ?? .distantPast) <= t.date && (kind == nil || $0.kind == kind) }
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    ScreenHeader(title: "Inbox", subtitle: "Everything Deck did for you, in one calm list.")
                    Button("Mark all read") { all.forEach { $0.read = true }; try? context.save() }
                        .buttonStyle(.pill).disabled(!all.contains { !$0.read })
                }
                filters
                let today = shown.filter { Calendar.current.isDateInToday($0.date) }
                let earlier = shown.filter { !Calendar.current.isDateInToday($0.date) }
                if shown.isEmpty {
                    Tile { Text("Nothing here. Deck will let you know when something happens.").font(F.body).foregroundStyle(C.text2) }
                }
                if !today.isEmpty { section("Today", today) }
                if !earlier.isEmpty { section("Earlier", earlier) }
            }
        }
    }

    private var filters: some View {
        let kinds = Array(Set(all.map(\.kind))).sorted()
        return HStack(spacing: 6) {
            pill("All", kind == nil) { kind = nil }
            ForEach(kinds, id: \.self) { k in pill(Inbox.kindNames[k] ?? k.capitalized, kind == k) { kind = k } }
        }
    }

    private func pill(_ title: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(F.ui(12, medium: on)).padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(on ? accent.fill : .clear))
                .overlay(Capsule().strokeBorder(on ? accent.border : C.border, lineWidth: 0.5))
                .foregroundStyle(on ? accent.soft : C.text2)
        }
        .buttonStyle(.plain)
    }

    private func section(_ title: String, _ items: [Activity]) -> some View {
        Tile {
            TileLabel(text: title)
            VStack(spacing: 0) {
                ForEach(items) { a in row(a, last: a.id == items.last?.id) }
            }
        }
    }

    private func row(_ a: Activity, last: Bool) -> some View {
        Row(divider: !last) {
            Text(Calendar.current.isDateInToday(a.date) ? clock(a.date) : a.date.formatted(.dateTime.day().month(.abbreviated)))
                .font(F.mono(11)).foregroundStyle(C.muted).frame(width: 52, alignment: .leading)
            Dot(color: a.read ? .clear : accent.accent)
            Text(a.text).font(F.body).foregroundStyle(a.read ? C.text2 : C.text).lineLimit(2)
            Spacer()
            if let path = a.fileURL {
                let url = URL(fileURLWithPath: path)
                Button("Open") { NSWorkspace.shared.open(url); markRead(a) }.buttonStyle(.pill)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.pill)
            }
            Menu("Snooze") {
                Button("For 1 hour") { snooze(a, until: .now.addingTimeInterval(3600)) }
                Button("Until tomorrow") {
                    let morning = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0,
                                                        of: Calendar.current.date(byAdding: .day, value: 1, to: .now)!)!
                    snooze(a, until: morning)
                }
            }
            .menuStyle(.borderlessButton).fixedSize().font(F.ui(12, medium: true))
            if !a.read { Button("Done") { markRead(a) }.buttonStyle(.pill) }
        }
    }

    private func markRead(_ a: Activity) { a.read = true; try? context.save() }
    private func snooze(_ a: Activity, until: Date) { a.snoozedUntil = until; try? context.save() }
}
