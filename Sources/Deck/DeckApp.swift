import SwiftUI
import SwiftData

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
        }
        .modelContainer(Store.container)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra {
            MenuBarPanel()
                .environment(\.accent, Accent.named(themeID))
                .modelContainer(Store.container)
                .preferredColorScheme(.dark)
        } label: {
            Image(systemName: "square.grid.2x2")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(\.accent, Accent.named(themeID))
                .preferredColorScheme(.dark)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let services = ServicesProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftPM executables launch as background tools unless told otherwise.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.servicesProvider = services
        Task { @MainActor in
            Downloads.shared.start()
            QuickCapture.install()
            Clipboard.shared.start()
            Tidy.shared.startIfOn()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            Downloads.shared.stop()
            KeepAwake.shared.on = false
            Equalizer.shared.setOn(false)
        }
    }
}
