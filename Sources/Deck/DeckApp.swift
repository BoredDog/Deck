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
                .tint(C.lime)
                .animation(.easeInOut(duration: 0.2), value: themeID)
                .preferredColorScheme(.dark)
                .frame(minWidth: 960, minHeight: 640)
                .onAppear { Logo.applyAppIcon(themeID) }
                .onChange(of: themeID) { _, id in Logo.applyAppIcon(id) }
        }
        .modelContainer(Store.container)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultLaunchBehavior(.suppressed)   // never opens by itself; AppDelegate opens it unless started at login

        MenuBarExtra {
            MenuBarPanel()
                .environment(\.accent, Accent.named(themeID))
                .tint(C.lime)
                .modelContainer(Store.container)
                .preferredColorScheme(.dark)
        } label: {
            MenuBarIcon(image: Logo.menuBar(dot: NSColor(Accent.named(themeID).accent)))
        }
        .menuBarExtraStyle(.window)

        Window("Clipboard", id: "clipboard") {
            ClipboardWindow()
                .environment(\.accent, Accent.named(themeID))
                .tint(C.lime)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 640, height: 560)

        Settings {
            SettingsView()
                .environment(\.accent, Accent.named(themeID))
                .tint(C.lime)
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
    private var termSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A plain "kill" or logout's SIGTERM quits like ⌘Q, so cleanup (unblock sites, reset fans, stop helpers) still runs.
        signal(SIGTERM, SIG_IGN)
        termSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSignal?.setEventHandler { NSApp.terminate(nil) }
        termSignal?.resume()

        // Lives in the menu bar only; never in the Dock (LSUIElement in Info.plist, and this for dev runs).
        NSApp.setActivationPolicy(.accessory)
        NSApp.servicesProvider = services
        let atLogin = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem

        Task { @MainActor in
            Inbox.start()
            Downloads.shared.start()
            WidgetWriter.shared.start()
            QuickCapture.install()
            _ = await Permission.explain(.keychain)
            Clipboard.shared.start()
            Tidy.shared.startIfOn()
            Triggers.shared.start()
            Weather.shared.startIfOn()
            Updater.shared.start()
            LoginItem.enableOnFirstRun()
            // Started quietly at login: no window, everything else runs in the background.
            if !atLogin { MainWindow.open() }
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
    /// Set by the menu bar icon at launch (and by the window itself), so the window can open before any exists.
    static var opener: OpenWindowAction? {
        didSet { if waiting, opener != nil { waiting = false; open() } }
    }
    private static var waiting = false

    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            w.makeKeyAndOrderFront(nil)
        } else if let opener {
            opener(id: "main")
        } else {
            waiting = true
        }
    }
}

/// The menu bar icon. It's on screen from launch, so it hands SwiftUI's window opener to MainWindow.
private struct MenuBarIcon: View {
    let image: NSImage
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Image(nsImage: image).onAppear { if MainWindow.opener == nil { MainWindow.opener = openWindow } }
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
