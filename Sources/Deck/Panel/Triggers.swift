import SwiftUI
import AppKit
import ApplicationServices
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let quickPanel = Self("quickPanel", initial: .init(.space, modifiers: [.control, .option]))
}

/// Spots a double tap of Option alone: two press-release cycles, the second press within `gap` of the first release.
struct OptionTapDetector {
    var gap: TimeInterval = 0.35
    private var down: TimeInterval?          // when Option went down, while it's held alone
    private var lastRelease: TimeInterval?   // end of the first tap

    /// Feed every modifier change. Returns true when the second tap ends.
    mutating func flags(_ flags: NSEvent.ModifierFlags, at t: TimeInterval) -> Bool {
        let mods = flags.intersection([.shift, .control, .option, .command, .function])
        if mods == .option, down == nil {
            if let r = lastRelease, t - r > gap { lastRelease = nil }
            down = t
        } else if mods.isEmpty, let d = down {
            down = nil
            guard t - d <= gap else { lastRelease = nil; return false } // held, not tapped
            if lastRelease != nil { lastRelease = nil; return true }
            lastRelease = t
        } else {
            cancel()
        }
        return false
    }

    /// Any other key in between means it wasn't a double tap.
    mutating func cancel() { down = nil; lastRelease = nil }
}

/// The three ways to open the quick panel, each switchable in Settings.
@MainActor final class Triggers {
    static let shared = Triggers()
    static let optionKey = "panelOptionTap", cornerKey = "panelCorner", shortcutKey = "panelShortcut"

    private var monitors: [Any] = []
    private var detector = OptionTapDetector()
    private var cornerSince: Date?
    private var cornerFired = false
    private var shortcutInstalled = false

    private func on(_ key: String, default value: Bool) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? value }

    /// Safe to call again whenever a setting or the Accessibility permission changes.
    func start() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        detector.cancel()

        if on(Self.optionKey, default: true) {
            add([.flagsChanged, .keyDown]) { e in
                if e.type == .keyDown { Triggers.shared.detector.cancel(); return }
                if Triggers.shared.detector.flags(e.modifierFlags, at: e.timestamp) { QuickPanel.shared.toggle() }
            }
        }
        if on(Self.cornerKey, default: false) {
            add([.mouseMoved, .leftMouseDragged]) { _ in Triggers.shared.pointerMoved() }
        }

        if !shortcutInstalled {
            shortcutInstalled = true
            KeyboardShortcuts.onKeyUp(for: .quickPanel) { QuickPanel.shared.toggle() }
        }
        if on(Self.shortcutKey, default: true) { KeyboardShortcuts.enable(.quickPanel) } else { KeyboardShortcuts.disable(.quickPanel) }
    }

    /// Global monitors see other apps (needs Accessibility for keys); local ones see Deck's own windows.
    private func add(_ mask: NSEvent.EventTypeMask, _ handle: @escaping @MainActor (NSEvent) -> Void) {
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { e in MainActor.assumeIsolated { handle(e) } }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { e in MainActor.assumeIsolated { handle(e) }; return e }) { monitors.append(l) }
    }

    private static func inCorner(_ p: NSPoint) -> Bool {
        NSScreen.screens.contains { s in
            let f = s.frame
            return p.x >= f.maxX - 2 && p.x <= f.maxX && p.y >= f.maxY - 2 && p.y <= f.maxY
        }
    }

    /// Fires once per visit after the pointer rests in a top-right corner for 250 ms.
    private func pointerMoved() {
        guard Self.inCorner(NSEvent.mouseLocation) else { cornerSince = nil; cornerFired = false; return }
        guard cornerSince == nil else { return }
        let since = Date()
        cornerSince = since
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            MainActor.assumeIsolated {
                let t = Triggers.shared
                guard t.cornerSince == since, !t.cornerFired, Self.inCorner(NSEvent.mouseLocation) else { return }
                t.cornerFired = true
                QuickPanel.shared.toggle()
            }
        }
    }
}

/// The quick panel part of Settings.
struct PanelSettingsSection: View {
    @AppStorage(Triggers.optionKey) private var optionTap = true
    @AppStorage(Triggers.cornerKey) private var corner = false
    @AppStorage(Triggers.shortcutKey) private var shortcut = true
    @State private var trusted = AXIsProcessTrusted()

    var body: some View {
        Tile {
            TileLabel(text: "Quick panel")
            Text("Slides in from the right, over any app.").font(F.body).foregroundStyle(C.text2)
            Row {
                Text("Double-tap Option").font(F.body)
                Spacer()
                Toggle("", isOn: $optionTap).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            if optionTap && !trusted {
                HStack {
                    Text("Deck needs Accessibility permission to notice the Option key.").font(F.label).foregroundStyle(C.text2)
                    Spacer()
                    Button("Allow") { askAccessibility() }.buttonStyle(.pill)
                }
                .padding(.vertical, 4)
            }
            Row {
                Text("Pointer into the top-right corner").font(F.body)
                Spacer()
                Toggle("", isOn: $corner).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            Row {
                Text("Keyboard shortcut").font(F.body)
                Spacer()
                KeyboardShortcuts.Recorder(for: .quickPanel).disabled(!shortcut)
                Toggle("", isOn: $shortcut).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            Text("What it shows").font(F.ui(12, medium: true)).foregroundStyle(C.text2).padding(.top, 8)
            PanelTileSwitches(key: PanelTile.quickPanelKey, tiles: PanelTile.quickPanel)
        }
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: optionTap) { Triggers.shared.start() }
        .onChange(of: corner) { Triggers.shared.start() }
        .onChange(of: shortcut) { Triggers.shared.start() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            let now = AXIsProcessTrusted()
            if now != trusted { trusted = now; Triggers.shared.start() } // key monitors only hear other apps once trusted
        }
    }

    private func askAccessibility() {
        Task { @MainActor in
            guard await Permission.explain(.accessibility) else { return }
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }
}
