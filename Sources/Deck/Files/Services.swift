import AppKit

/// Files handed over from Finder's right-click menu ("Convert with Deck", "Make Smaller with Deck").
@MainActor final class Incoming: ObservableObject {
    static let shared = Incoming()
    @Published var convert: [URL] = []
    @Published var compress: [URL] = []
}

final class ServicesProvider: NSObject {
    @objc func convertFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        hand(pboard, tool: .convert)
    }

    @objc func compressFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        hand(pboard, tool: .smaller)
    }

    private func hand(_ pboard: NSPasteboard, tool: FileTool) {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        Task { @MainActor in
            UserDefaults.standard.set(Place.files.rawValue, forKey: "place")
            UserDefaults.standard.set(tool.rawValue, forKey: "filesTool")
            if tool == .convert { Incoming.shared.convert = urls } else { Incoming.shared.compress = urls }
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
    }
}
