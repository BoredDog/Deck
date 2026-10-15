import AppIntents
import SwiftUI
import WidgetKit

// Notification Center / desktop widgets. They only read the snapshot Deck writes to the App Group folder
// (Sources/Deck/Widgets/WidgetSnapshot.swift); the extension is sandboxed and has no network.

@main struct DeckWidgets: WidgetBundle {
    var body: some Widget {
        FocusWidget()
        NextUpWidget()
        TasksWidget()
        DownloadsWidget()
        MacWidget()
        SavedWidget()
    }
}

struct Entry: TimelineEntry { let date: Date; let snapshot: WidgetSnapshot? }

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: .now, snapshot: .sample) }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now, snapshot: WidgetSnapshot.load() ?? (context.isPreview ? .sample : nil)))
    }

    /// Deck reloads us when something changes; otherwise look again every 15 minutes.
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: .now, snapshot: WidgetSnapshot.load())], policy: .after(.now + 15 * 60)))
    }
}

/// Ticks a task in the widget right away and leaves its id for Deck, which completes it in Reminders.
/// Chosen over EventKit here: the extension can't show the Reminders permission prompt, Deck already has access.
struct CompleteTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Complete task"
    static let isDiscoverable = false
    @Parameter(title: "Task") var id: String

    init() {}
    init(id: String) { self.id = id }

    func perform() async throws -> some IntentResult {
        if var s = WidgetSnapshot.load(), let i = s.tasks.firstIndex(where: { $0.id == id }) {
            s.tasks[i].done = true
            try? s.save()
        }
        if let url = WidgetSnapshot.completeURL {
            let line = Data((id + "\n").utf8)
            if let h = try? FileHandle(forWritingTo: url) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: line)
                try? h.close()
            } else {
                try? line.write(to: url, options: .atomic)
            }
        }
        DistributedNotificationCenter.default().postNotificationName(WidgetSnapshot.requestNotification, object: nil, deliverImmediately: true)
        return .result()
    }
}

// MARK: widgets

private func deckWidget<V: View>(_ kind: String, _ name: String, _ about: String,
                                 @ViewBuilder _ content: @escaping (WidgetSnapshot, WidgetFamily) -> V) -> some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: Provider()) { Shell(entry: $0, content: content) }
        .configurationDisplayName(name)
        .description(about)
        .supportedFamilies([.systemSmall, .systemMedium])
}

struct FocusWidget: Widget {
    var body: some WidgetConfiguration {
        deckWidget("focus", "Focus", "Your focus streak and time this week.") { s, f in FocusView(s: s, family: f) }
    }
}

struct NextUpWidget: Widget {
    var body: some WidgetConfiguration {
        deckWidget("next", "Next up", "Your next event.") { s, _ in NextUpView(s: s) }
    }
}

struct TasksWidget: Widget {
    var body: some WidgetConfiguration {
        deckWidget("tasks", "Today's tasks", "Tasks due today. Tap one to check it off.") { s, f in TasksView(s: s, family: f) }
    }
}

struct DownloadsWidget: Widget {
    var body: some WidgetConfiguration {
        deckWidget("downloads", "Downloads", "How far your download has got.") { s, _ in DownloadView(s: s) }
    }
}

struct MacWidget: Widget {
    var body: some WidgetConfiguration {
        deckWidget("mac", "Mac status", "Processor, memory and free space.") { s, f in MacStatusView(s: s, family: f) }
    }
}

struct SavedWidget: Widget {
    var body: some WidgetConfiguration {
        deckWidget("saved", "Space saved", "Space Deck has freed up for you.") { s, _ in SavedView(s: s) }
    }
}

extension WidgetSnapshot {
    /// Shown in the widget gallery before Deck has written anything.
    static let sample: WidgetSnapshot = {
        var s = WidgetSnapshot()
        s.streakDays = 4
        s.focusMinutesThisWeek = 245
        s.nextEventTitle = "Design review"
        s.nextEventStart = .now + 25 * 60
        s.tasks = [.init(id: "1", title: "Send the invoice", due: nil, done: false),
                   .init(id: "2", title: "Book flights", due: nil, done: false),
                   .init(id: "3", title: "Call mom", due: nil, done: true)]
        s.download = .init(name: "ubuntu-24.04.iso", progress: 0.62)
        s.cpu = 0.18
        s.memory = 0.54
        s.diskFree = 182_000_000_000
        s.savedBytes = 3_400_000_000
        return s
    }()
}
