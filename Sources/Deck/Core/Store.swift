import Foundation
import SwiftData

/// One line in the activity feed / Inbox: "Converted holiday.mov", "Saved 1.2 GB".
@Model final class Activity {
    var date: Date
    var text: String
    var savedBytes: Int64
    var read: Bool
    var fileURL: String?
    var kind: String = "info"      // "download", "convert", "event", "task", "focus", "break", "info"
    var urgent: Bool = false
    var snoozedUntil: Date?

    init(_ text: String, kind: String = "info", urgent: Bool = false, savedBytes: Int64 = 0, file: URL? = nil) {
        self.kind = kind
        self.urgent = urgent
        self.date = .now
        self.text = text
        self.savedBytes = savedBytes
        self.read = false
        self.fileURL = file?.path
    }
}

@Model final class FocusSession {
    var start: Date
    var minutes: Int
    init(start: Date, minutes: Int) { self.start = start; self.minutes = minutes }
}

@MainActor enum Store {
    static let container: ModelContainer = {
        let models: [any PersistentModel.Type] = [Activity.self, FocusSession.self] + PlanModels.all + FocusModels.all + NotesModels.all + InboxModels.all
        let schema = Schema(models)
        if let c = try? ModelContainer(for: schema) { return c }
        // shortcut: falls back to memory-only if the store can't open, so the app still launches.
        return try! ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }()

    static var context: ModelContext { container.mainContext }

    static func log(_ text: String, kind: String = "info", urgent: Bool = false, saved: Int64 = 0, file: URL? = nil) {
        let a = Activity(text, kind: kind, urgent: urgent, savedBytes: saved, file: file)
        context.insert(a)
        try? context.save()
        Inbox.deliver(a)
    }
}
