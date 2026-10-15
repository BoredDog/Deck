import Foundation
import SwiftData
import CoreData

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
        let url = Vault.folder.appendingPathComponent("Deck.store")
        copyOldStore(to: url, schema: schema)
        if let c = try? ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url)) { return c }
        // Falls back to memory-only so the app still launches; Home warns the user.
        isMemoryOnly = true
        return try! ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }()

    /// True when the database couldn't open and Deck is running without saving (shown as a warning on Home).
    static var isMemoryOnly = false

    static var context: ModelContext { container.mainContext }

    /// Deck 1.0 used SwiftData's shared default.store in Application Support. Copies it (never moves: it may belong to
    /// another app) once, and only if it opens with Deck's models.
    static func copyOldStore(to url: URL, schema: Schema,
                             from old: URL = URL.applicationSupportDirectory.appendingPathComponent("default.store")) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: url.path) else { return }
        let suffixes = ["", "-shm", "-wal"]
        let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: temp) }
        do {
            // Opened from a copy, so a failed check can't touch the original.
            try fm.createDirectory(at: temp, withIntermediateDirectories: true)
            let probe = temp.appendingPathComponent("default.store")
            for s in suffixes where fm.fileExists(atPath: old.path + s) { try fm.copyItem(atPath: old.path + s, toPath: probe.path + s) }
            // Only Deck's own data: the store must already hold Deck's models, not just open with them.
            let meta = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: probe)
            let entities = meta["NSStoreModelVersionHashes"] as? [String: Any] ?? [:]
            guard entities["Activity"] != nil, entities["FocusSession"] != nil else { return }
            let c = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: probe, allowsSave: false))
            _ = try ModelContext(c).fetchCount(FetchDescriptor<Activity>())
            for s in suffixes where fm.fileExists(atPath: old.path + s) { try fm.copyItem(atPath: old.path + s, toPath: url.path + s) }
        } catch {
            for s in suffixes { try? fm.removeItem(atPath: url.path + s) }
        }
    }

    static func log(_ text: String, kind: String = "info", urgent: Bool = false, saved: Int64 = 0, file: URL? = nil) {
        let a = Activity(text, kind: kind, urgent: urgent, savedBytes: saved, file: file)
        context.insert(a)
        try? context.save()
        Inbox.deliver(a)
    }
}
