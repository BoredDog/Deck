import Foundation

// Shared contract between the organizer engine (OrganizeEngine.swift) and its screens (OrganizeView.swift).
// Stubs here are replaced by the engine; keep these names and shapes stable.

enum GroupBy: String, CaseIterable, Codable, Identifiable {
    case type = "Type", date = "Date", course = "Course", rules = "My rules"
    var id: String { rawValue }
}

struct OrganizeOptions: Codable, Equatable {
    var primary: GroupBy = .type
    var secondary: GroupBy? = nil
    var cleanNames = false
    var includeSubfolders = false
}

/// "If <field> <value> → put it in <folder>". Rules are checked in order; the first match wins.
struct OrganizeRule: Codable, Identifiable, Equatable {
    enum Field: String, Codable, CaseIterable { case nameContains = "Name contains", extensionIs = "File type is",
        fromSiteContains = "Downloaded from", olderThanDays = "Older than (days)", largerThanMB = "Bigger than (MB)" }
    var id = UUID()
    var field: Field
    var value: String
    var folder: String
}

/// One proposed move (and/or rename). `include` is the checkbox in the preview.
struct PlannedMove: Identifiable, Equatable {
    let id = UUID()
    let source: URL
    var destination: URL
    var reason: String        // plain words, e.g. "Slides · Linear Algebra"
    var include = true
}

/// What was moved, so it can be undone (persisted by the engine).
struct UndoRecord: Codable, Equatable {
    var date: Date
    var folder: URL
    var moves: [Pair]
    struct Pair: Codable, Equatable { var from: URL; var to: URL }
}

/// Extra clean-up suggestions shown under the move preview.
struct CleanupFindings {
    var oldInstallers: [URL] = []      // .dmg/.pkg whose app is already installed
    var duplicates: [[URL]] = []       // identical files; the first of each group is the one to keep
    var bigForgotten: [URL] = []       // large and unopened for months
}
