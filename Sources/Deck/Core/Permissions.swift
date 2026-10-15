import AppKit

/// A short note from Deck, shown once right before macOS asks for a permission, saying why.
enum Permission: String, CaseIterable {
    case calendar, notifications, accessibility, location, automation, audioCapture, fullDiskAccess, loginItems, keychain, adminPassword

    var title: String {
        switch self {
        case .calendar: "Deck would like to see your calendar and reminders"
        case .notifications: "Deck would like to send you notifications"
        case .accessibility: "Deck needs Accessibility for the Option double-tap"
        case .location: "Deck needs your location for the weather"
        case .automation: "Deck would like to control another app"
        case .audioCapture: "Deck needs to hear your Mac's sound for the equalizer"
        case .fullDiskAccess: "Deck can search and tidy your whole disk"
        case .loginItems: "One-time approval for Deck's helper"
        case .keychain: "Deck keeps one private key in your Keychain"
        case .adminPassword: "Deck needs your password to block websites"
        }
    }

    var why: String {
        switch self {
        case .calendar:
            "So Plan can show your events and tasks, and add the ones you type. Everything stays on this Mac. If you say no, Plan stays empty and the rest of Deck works."
        case .notifications:
            "So Deck can tell you when downloads finish, events start or it's time for a break. If you say no, everything still shows in Inbox."
        case .accessibility:
            "macOS only lets apps notice the Option key this way with Accessibility. Deck looks at the Option key only, never what you type. If you say no, use the keyboard shortcut or the top-right corner instead."
        case .location:
            "Your location is rounded to about 1 km and used only to get a forecast. If you say no, the weather tile stays off."
        case .automation:
            "So Deck can play and pause Spotify or Music, or export Pages, Numbers and Keynote files you ask it to convert. macOS asks once per app. If you say no, those buttons won't work."
        case .audioCapture:
            "The equalizer adjusts sound as it plays, so Deck has to hear it. Nothing is recorded or saved. If you say no, the equalizer stays off."
        case .fullDiskAccess:
            "Find and Storage can only see your home folder unless you give Deck Full Disk Access in System Settings. Results never leave this Mac."
        case .loginItems:
            "A small helper lets Deck block websites and control fans without asking for your password every time. macOS will ask you to turn Deck on under Login Items."
        case .keychain:
            "It encrypts your clipboard history, journal and private notes. If macOS asks, choose Always Allow. If you deny, those stay in memory only and nothing is lost."
        case .adminPassword:
            "Blocking websites means changing a system file, which needs your Mac password. To stop being asked, set up the helper in Focus → Block distractions."
        }
    }

    private static func key(_ p: Permission) -> String { "explained.\(p.rawValue)" }

    static func wasExplained(_ p: Permission, in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key(p))
    }

    /// Shows the note the first time; returns false if the user picks "Not now" (asked again next time).
    @MainActor static func explain(_ p: Permission, in defaults: UserDefaults = .standard) async -> Bool {
        guard !wasExplained(p, in: defaults) else { return true }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = p.title
        alert.informativeText = p.why
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Not now")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        defaults.set(true, forKey: key(p))
        return true
    }
}
