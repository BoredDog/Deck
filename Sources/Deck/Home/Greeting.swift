import Foundation

/// The Home greeting: changes each time you open Deck and fits the time of day. "{name}" becomes your name.
enum Greeting {
    static let morning = [
        "Good morning, {name}",
        "Morning, {name}. Coffee first?",
        "Rise and grind, {name}",
        "Early start, {name}? Nice.",
        "Fresh day, {name}. What's first?",
    ]
    static let afternoon = [
        "Good afternoon, {name}",
        "Back at it, {name}?",
        "Halfway through the day, {name}",
        "Lecture done, {name}? Let's get going.",
        "Afternoon focus, {name}?",
    ]
    static let evening = [
        "Good evening, {name}",
        "Evening study session, {name}?",
        "Winding down, {name}?",
        "One more thing before dinner, {name}?",
        "Let's wrap up the day, {name}",
    ]
    static let night = [
        "Burning the midnight oil, {name}?",
        "Late one tonight, {name}?",
        "Night owl mode, {name}",
        "Deadline tonight, {name}? You've got this.",
        "Don't forget to sleep, {name}",
    ]

    static func options(hour: Int) -> [String] {
        switch hour {
        case 5..<12: morning
        case 12..<17: afternoon
        case 17..<22: evening
        default: night
        }
    }

    /// A greeting for this time of day, different from last time.
    static func pick(hour: Int = Calendar.current.component(.hour, from: .now), defaults: UserDefaults = .standard) -> String {
        let last = defaults.string(forKey: "lastGreeting")
        let line = options(hour: hour).filter { $0 != last }.randomElement()!
        defaults.set(line, forKey: "lastGreeting")
        return line
    }

    static func fill(_ template: String, name: String) -> String {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty {
            // No name: drop it along with the comma or space next to it.
            return template.replacingOccurrences(of: ", {name}", with: "").replacingOccurrences(of: " {name}", with: "")
        }
        return template.replacingOccurrences(of: "{name}", with: n)
    }
}
