import Foundation

// Temporary stand-in until OrganizeEngine.swift lands. Delete when the real `Organizer` compiles.
enum Organizer {
    static func plan(folder: URL, options: OrganizeOptions, rules: [OrganizeRule], courses: [String]) async -> [PlannedMove] { [] }
    @MainActor static func apply(_ moves: [PlannedMove]) throws -> UndoRecord { UndoRecord(date: Date(), folder: URL(fileURLWithPath: "/"), moves: []) }
    @MainActor static func undo(_ record: UndoRecord) throws {}
    static var lastRecord: UndoRecord? { nil }
    static func cleanName(_ name: String) -> String { name }
    static func cleanup(in folder: URL, includeSubfolders: Bool) async -> CleanupFindings { CleanupFindings() }
    static func knownCourses() async -> [String] { [] }
}
