import XCTest
import SwiftUI
@testable import Deck

/// Renders every screen to PNG for a visual check. Only runs when DECK_SNAPSHOTS points at a folder.
final class SnapshotTests: XCTestCase {
    @MainActor func testRenderScreens() throws {
        guard let dir = ProcessInfo.processInfo.environment["DECK_SNAPSHOTS"] else { throw XCTSkip("set DECK_SNAPSHOTS to render") }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        func render<V: View>(_ name: String, width: CGFloat = 770, _ view: V) {
            let content = view
                .padding(24)
                .frame(width: width, alignment: .topLeading)
                .background(C.bg)
                .foregroundStyle(C.text)
                .environment(\.accent, Accent.all[0])
                .modelContainer(Store.container)
                .environment(\.colorScheme, .dark)
            let r = ImageRenderer(content: content)
            r.scale = 1
            guard let img = r.nsImage, let tiff = img.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                return XCTFail("could not render \(name)")
            }
            try? png.write(to: out.appendingPathComponent("\(name).png"))
        }

        render("home", HomeView())
        render("files", FilesView())
        render("find", FindView())
        render("mac", MacView())
        render("downloads", DownloadsView())
        render("plan", PlanView())
        render("focus", FocusView())
        render("notes", NotesView())
        render("inbox", InboxView())
        render("settings", width: 560, SettingsView())
        render("menubar", width: 340, MenuBarPanel())
        render("quickpanel", width: 380, QuickPanelView())
    }
}
