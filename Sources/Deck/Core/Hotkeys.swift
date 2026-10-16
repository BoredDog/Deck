import SwiftUI
import Carbon.HIToolbox

/// Deck's global shortcuts (quick panel, quick note) without extra packages. Uses Carbon hot keys, which need
/// no Accessibility permission. (KeyboardShortcuts was dropped: its resource bundle can't live inside a signed app.)
struct Hotkey: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32      // Carbon flags: cmdKey, optionKey, controlKey, shiftKey
    var display: String        // e.g. "⌃⌥Space"
}

enum HotkeyName: String, CaseIterable {
    case quickPanel, quickCapture

    var defaultKey: Hotkey {
        switch self {
        case .quickPanel: Hotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), display: "⌃⌥Space")
        // ⌃⌥N: ⌥⌘N is Finder's "New Smart Folder".
        case .quickCapture: Hotkey(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | optionKey), display: "⌃⌥N")
        }
    }

    var id: UInt32 { self == .quickPanel ? 1 : 2 }
}

@MainActor enum Hotkeys {
    private static var refs: [UInt32: EventHotKeyRef] = [:]
    private static var actions: [UInt32: () -> Void] = [:]
    private static var disabled: Set<UInt32> = []
    private static var handlerInstalled = false

    /// The shortcut in use: the saved one, the default if never changed, or nil if the person cleared it.
    static func current(_ name: HotkeyName) -> Hotkey? {
        let d = UserDefaults.standard
        if d.bool(forKey: "hotkey.\(name.rawValue).cleared") { return nil }
        guard let data = d.data(forKey: "hotkey.\(name.rawValue)"), let hk = try? JSONDecoder().decode(Hotkey.self, from: data) else {
            return name.defaultKey
        }
        return hk
    }

    static func set(_ hotkey: Hotkey?, for name: HotkeyName) {
        let d = UserDefaults.standard
        d.set(hotkey == nil, forKey: "hotkey.\(name.rawValue).cleared")
        if let hotkey, let data = try? JSONEncoder().encode(hotkey) { d.set(data, forKey: "hotkey.\(name.rawValue)") }
        register(name)
    }

    /// Runs `action` whenever the shortcut is pressed anywhere.
    static func onPress(_ name: HotkeyName, _ action: @escaping () -> Void) {
        installHandler()
        actions[name.id] = action
        register(name)
    }

    static func setEnabled(_ name: HotkeyName, _ on: Bool) {
        if on { disabled.remove(name.id) } else { disabled.insert(name.id) }
        register(name)
    }

    /// While recording a new shortcut, the old one shouldn't fire.
    static func pause(_ name: HotkeyName) { unregister(name) }
    static func resume(_ name: HotkeyName) { register(name) }

    private static func register(_ name: HotkeyName) {
        unregister(name)
        guard actions[name.id] != nil, !disabled.contains(name.id), let hk = current(name) else { return }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4445_434B), id: name.id) // "DECK"
        if RegisterEventHotKey(hk.keyCode, hk.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            refs[name.id] = ref
        }
    }

    private static func unregister(_ name: HotkeyName) {
        if let ref = refs.removeValue(forKey: name.id) { UnregisterEventHotKey(ref) }
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let key = id.id
            DispatchQueue.main.async { MainActor.assumeIsolated { Hotkeys.actions[key]?() } }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Builds a shortcut from a key press; nil unless ⌘, ⌥ or ⌃ is held (plain letters would clash with typing).
    static func hotkey(from event: NSEvent) -> Hotkey? {
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !f.intersection([.command, .option, .control]).isEmpty else { return nil }
        var mods: UInt32 = 0, symbols = ""
        if f.contains(.control) { mods |= UInt32(controlKey); symbols += "⌃" }
        if f.contains(.option) { mods |= UInt32(optionKey); symbols += "⌥" }
        if f.contains(.shift) { mods |= UInt32(shiftKey); symbols += "⇧" }
        if f.contains(.command) { mods |= UInt32(cmdKey); symbols += "⌘" }
        return Hotkey(keyCode: UInt32(event.keyCode), modifiers: mods, display: symbols + keyName(event))
    }

    static func keyName(_ event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: "Space"
        case kVK_Return: "Return"
        case kVK_Tab: "Tab"
        case kVK_Delete: "Delete"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        case kVK_F1...kVK_F12: "F\(Int(event.keyCode))"
        default: (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }
}

/// A pill showing the shortcut; click it, then press the new keys. Esc cancels, Delete clears it.
struct HotkeyRecorder: View {
    let name: HotkeyName
    @State private var recording = false
    @State private var shown: Hotkey?
    @State private var monitor: Any?
    @Environment(\.accent) private var accent

    var body: some View {
        Button { recording ? stop() : start() } label: {
            Text(recording ? "Press keys…" : (shown?.display ?? "Not set"))
                .font(F.mono(12))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(recording ? accent.surface : accent.fill))
                .overlay(Capsule().strokeBorder(recording ? accent.accent : accent.border, lineWidth: 1))
                .foregroundStyle(accent.soft)
        }
        .buttonStyle(.plain)
        .help("Click, then press the new shortcut. Esc cancels, Delete clears it.")
        .accessibilityLabel("Shortcut: \(shown?.display ?? "not set")")
        .onAppear { shown = Hotkeys.current(name) }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        Hotkeys.pause(name)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            switch Int(e.keyCode) {
            case kVK_Escape: stop()
            case kVK_Delete, kVK_ForwardDelete:
                Hotkeys.set(nil, for: name); shown = nil; stop()
            default:
                guard let hk = Hotkeys.hotkey(from: e) else { return nil }   // needs ⌘, ⌥ or ⌃
                Hotkeys.set(hk, for: name); shown = hk; stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { recording = false; Hotkeys.resume(name) }
    }
}
