import Foundation

/// What the widgets show. Written by the app (WidgetWriter), read by the DeckWidgets extension; this file is compiled
/// into both. Only counts, titles and times: no file contents, no clipboard, no note text.
struct WidgetSnapshot: Codable, Equatable {
    struct Todo: Codable, Equatable, Identifiable { var id: String; var title: String; var due: Date?; var done: Bool }  // due only when it has a time
    struct Download: Codable, Equatable { var name: String; var progress: Double }

    var streakDays = 0
    var focusMinutesThisWeek = 0
    var nextEventTitle: String?
    var nextEventStart: Date?
    var tasks: [Todo] = []
    var download: Download?
    var cpu = 0.0           // 0…1
    var memory = 0.0        // 0…1
    var diskFree: Int64 = 0
    var savedBytes: Int64 = 0
    var accentHex: UInt32 = 0x4fc9b8
    var updated = Date.distantPast

    static let group = "group.com.nav.deck"
    /// Posted (without payload: sandboxed senders can't attach one) after a widget queues a task completion.
    static let requestNotification = Notification.Name("com.nav.deck.widgetRequest")

    static var folder: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) }
    static var fileURL: URL? { folder?.appendingPathComponent("widget.json") }
    /// Task ids ticked in a widget, one per line, waiting for the app to complete them in Reminders.
    static var completeURL: URL? { folder?.appendingPathComponent("complete.txt") }

    static func load() -> WidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    func save() throws {
        guard let url = Self.fileURL else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(self).write(to: url, options: .atomic)
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
