import SwiftUI
import SwiftData
import ServiceManagement

@main
struct DeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage("theme") private var themeID = Accent.all[0].id

    var body: some Scene {
        WindowGroup("Deck", id: "main") {
            RootView()
                .environment(\.accent, Accent.named(themeID))
                .animation(.easeInOut(duration: 0.2), value: themeID)
                .preferredColorScheme(.dark)
                .frame(minWidth: 960, minHeight: 640)
                .onAppear { Logo.applyAppIcon(themeID) }
                .onChange(of: themeID) { _, id in Logo.applyAppIcon(id) }
        }
        .modelContainer(Store.container)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra {
            MenuBarPanel()
                .environment(\.accent, Accent.named(themeID))
                .modelContainer(Store.container)
                .preferredColorScheme(.dark)
        } label: {
            Image(nsImage: Logo.menuBar(dot: NSColor(Accent.named(themeID).accent)))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(\.accent, Accent.named(themeID))
                .preferredColorScheme(.dark)
        }
    }
}

extension Logo {
    /// The running app's icon shows the current theme's dot.
    @MainActor static func applyAppIcon(_ themeID: String) {
        NSApp.applicationIconImage = appIcon(dot: NSColor(Accent.named(themeID).accent))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let services = ServicesProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Lives in the menu bar only; never in the Dock (LSUIElement in Info.plist, and this for dev runs).
        NSApp.setActivationPolicy(.accessory)
        NSApp.servicesProvider = services
        let atLogin = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem

        Task { @MainActor in
            Inbox.start()
            Downloads.shared.start()
            QuickCapture.install()
            Clipboard.shared.start()
            Tidy.shared.startIfOn()
            Triggers.shared.start()
            Weather.shared.startIfOn()
            LoginItem.enableOnFirstRun()
            if atLogin {
                // Started quietly at login: keep the window closed, everything else runs in the background.
                NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix("main") == true }.forEach { $0.close() }
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    /// Clicking the app again (Finder, Spotlight) brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { MainWindow.open() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            Downloads.shared.stop()
            KeepAwake.shared.on = false
            Equalizer.shared.setOn(false)
        }
    }
}

/// Opens (or re-opens) the main window from anywhere: menu bar, quick panel, Finder.
@MainActor enum MainWindow {
    static var opener: OpenWindowAction?

    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            opener?(id: "main")
        }
    }
}

/// Launch at login: on by default the first time, then whatever the user picks in Settings.
@MainActor enum LoginItem {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
    }

    static func enableOnFirstRun() {
        guard Bundle.main.bundleIdentifier != nil, !UserDefaults.standard.bool(forKey: "loginItemDecided") else { return }
        UserDefaults.standard.set(true, forKey: "loginItemDecided")
        set(true)
    }
}
