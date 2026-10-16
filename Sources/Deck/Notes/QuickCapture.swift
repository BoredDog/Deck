import SwiftUI
import AppKit
import EventKit


/// A shortcut (⌃⌥N unless changed in Settings) opens a small box from anywhere.
/// Enter adds to the Inbox note, ⌘Enter adds a reminder. Needs no Accessibility permission.
@MainActor enum QuickCapture {
    private static var installed = false
    private static var panel: NSPanel?
    private static let reminders = EKEventStore()

    static func install() {
        guard !installed else { return }
        installed = true
        Hotkeys.onPress(.quickCapture) { QuickCapture.toggle() }
    }

    /// Plain text of the current shortcut, e.g. "⌃⌥N", or nil when it's switched off.
    static var shortcutText: String? { Hotkeys.current(.quickCapture)?.display }

    static func toggle() {
        if let p = panel, p.isVisible { close(); return }
        let p = panel ?? makePanel()
        panel = p
        p.contentView = NSHostingView(rootView: CaptureBox().environment(\.accent, Accent.named(UserDefaults.standard.string(forKey: "theme") ?? "")))
        p.center()
        p.makeKeyAndOrderFront(nil)
    }

    static func close() { panel?.orderOut(nil) }

    private static func makePanel() -> NSPanel {
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 96),
                         styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.backgroundColor = .black
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.appearance = NSAppearance(named: .darkAqua)
        return p
    }

    /// Adds a reminder to the default list. macOS asks for Reminders access the first time.
    static func addReminder(_ title: String) async -> Bool {
        guard await Permission.explain(.calendar), (try? await reminders.requestFullAccessToReminders()) == true,
              let list = reminders.defaultCalendarForNewReminders() else { return false }
        let r = EKReminder(eventStore: reminders)
        r.title = title
        r.calendar = list
        return (try? reminders.save(r, commit: true)) != nil
    }
}

/// The Notes part of Settings: change the quick capture shortcut.
struct NotesSettingsSection: View {
    var body: some View {
        Tile {
            TileLabel(text: "Quick note")
            HStack {
                Text("Jot a note from anywhere").font(F.body)
                Spacer()
                HotkeyRecorder(name: .quickCapture)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A panel that can take typing without bringing the whole app forward.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

private struct CaptureBox: View {
    @State private var text = ""
    @State private var note = "Return saves it to your Inbox note · ⌘Return makes it a reminder"
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Jot something down", text: $text)
                .textFieldStyle(.plain).font(F.ui(18))
                .focused($focused)
                .onSubmit { save() }
            Text(note).font(F.label).foregroundStyle(C.text2)
            // Hidden button so ⌘Enter works while typing.
            Button("") { remind() }.keyboardShortcut(.return, modifiers: .command).hidden().frame(height: 0)
        }
        .padding(16)
        .frame(width: 460, alignment: .leading)
        .background(C.bg)
        .foregroundStyle(C.text)
        .onAppear { focused = true }
    }

    private func save() {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        NoteFiles.appendToInbox(text)
        text = ""
        QuickCapture.close()
    }

    private func remind() {
        let title = text.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        Task {
            if await QuickCapture.addReminder(title) {
                text = ""
                QuickCapture.close()
            } else {
                note = "Deck needs Reminders access for this. Turn it on in System Settings → Privacy → Reminders."
            }
        }
    }
}
