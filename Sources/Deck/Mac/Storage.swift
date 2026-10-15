import AppKit

/// A folder and how much space it uses. Only folders of 1 MB or more keep their children, to stay light on memory.
struct SizeNode: Identifiable {
    let url: URL
    let size: Int64
    let children: [SizeNode]
    var id: String { url.path }
    var name: String { url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent }
}

/// Collects large or long-untouched files while the size scan runs.
final class BigFiles: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var hits: [Hit] = []
    let yearAgo = Date().addingTimeInterval(-365 * 86400)

    func consider(_ url: URL, size: Int64, touched: Date) {
        // shortcut: "old" also needs 50 MB so tiny forgotten files don't flood the list.
        guard size > 500_000_000 || (touched < yearAgo && size > 50_000_000) else { return }
        lock.withLock { hits.append(Hit(path: url.path, size: size, modified: touched, isFolder: false)) }
    }
}

enum SpaceScan {
    static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .contentModificationDateKey, .contentAccessDateKey]
    /// Other volumes and the firmlinked data volume would be counted twice when scanning from /.
    static let skip: Set<String> = ["/System/Volumes", "/Volumes", "/dev", "/net", "/home"]

    static func scan(_ url: URL, depth: Int = 0, big: BigFiles, progress: ((Double) -> Void)? = nil) -> SizeNode {
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)) ?? []
        let lock = NSLock()
        var size: Int64 = 0, kids: [SizeNode] = [], done = 0
        // Spread the first two levels across cores; deeper levels run inline.
        DispatchQueue.concurrentPerform(iterations: depth < 2 ? items.count : 0) { i in
            let n = visit(items[i], depth: depth, big: big)
            lock.withLock {
                size += n.size; if let node = n.node { kids.append(node) }
                done += 1
                progress?(Double(done) / Double(items.count))
            }
        }
        if depth >= 2 {
            for item in items {
                let n = visit(item, depth: depth, big: big)
                size += n.size; if let node = n.node { kids.append(node) }
            }
        }
        return SizeNode(url: url, size: size, children: kids.filter { $0.size >= 1_000_000 }.sorted { $0.size > $1.size })
    }

    private static func visit(_ item: URL, depth: Int, big: BigFiles) -> (size: Int64, node: SizeNode?) {
        guard !skip.contains(item.path), let v = try? item.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true else { return (0, nil) }
        if v.isDirectory == true {
            let node = scan(item, depth: depth + 1, big: big)
            return (node.size, node)
        }
        let s = Int64(v.totalFileAllocatedSize ?? 0)
        big.consider(item, size: s, touched: max(v.contentModificationDate ?? .distantPast, v.contentAccessDate ?? .distantPast))
        return (s, nil)
    }
}

/// One thing the cleanup can remove.
struct CleanItem: Identifiable {
    enum Group: String, CaseIterable { case caches = "App caches", logs = "Logs", xcode = "Xcode leftovers", backups = "Old iPhone backups", installers = "Installers in Downloads", trash = "Trash" }
    let url: URL
    let group: Group
    let label: String
    var size: Int64 = 0
    var id: String { url.path }
}

/// The ONLY places cleanup may touch. Everything is checked against `allowed` again right before it moves.
enum Cleanup {
    static func groupFor(_ url: URL, home: URL, now: Date = .now) -> CleanItem.Group? {
        let path = url.standardizedFileURL.path
        let parent = url.standardizedFileURL.deletingLastPathComponent().path
        let lib = home.appendingPathComponent("Library").path
        switch parent {
        case lib + "/Caches": return .caches
        case lib + "/Logs": return .logs
        case lib + "/Application Support/MobileSync/Backup":
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            return date < now.addingTimeInterval(-90 * 86400) ? .backups : nil
        case home.appendingPathComponent("Downloads").path:
            return ["dmg", "pkg"].contains(url.pathExtension.lowercased()) ? .installers : nil
        default: break
        }
        if path == lib + "/Developer/Xcode/DerivedData" || path == lib + "/Developer/CoreSimulator/Caches" { return .xcode }
        if path == home.appendingPathComponent(".Trash").path { return .trash }
        return nil
    }

    static func allowed(_ url: URL, home: URL) -> Bool { groupFor(url, home: home) != nil }

    /// Lists what could be cleaned, without sizes (those are slow; the caller fills them in).
    static func candidates(home: URL) -> [CleanItem] {
        let fm = FileManager.default
        let lib = home.appendingPathComponent("Library")
        func children(_ dir: URL) -> [URL] { (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] }
        let urls = children(lib.appendingPathComponent("Caches")) + children(lib.appendingPathComponent("Logs"))
            + [lib.appendingPathComponent("Developer/Xcode/DerivedData"), lib.appendingPathComponent("Developer/CoreSimulator/Caches")]
            + children(lib.appendingPathComponent("Application Support/MobileSync/Backup"))
            + children(home.appendingPathComponent("Downloads"))
        var items = urls.filter { fm.fileExists(atPath: $0.path) }.compactMap { url in
            groupFor(url, home: home).map { CleanItem(url: url, group: $0, label: label(url, $0)) }
        }
        let trash = home.appendingPathComponent(".Trash")
        if !children(trash).isEmpty { items.append(CleanItem(url: trash, group: .trash, label: "Empty the Trash")) }
        return items
    }

    /// Friendly names: "Spotify" instead of "com.spotify.client".
    static func label(_ url: URL, _ group: CleanItem.Group) -> String {
        let name = url.lastPathComponent
        switch group {
        case .xcode: return name == "DerivedData" ? "Xcode build files" : "iPhone simulator caches"
        case .backups:
            let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return "iPhone backup" + (d.map { " from \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "")
        case .caches, .logs:
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
                return FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
            }
            return name
        default: return name
        }
    }

    /// Moves items to the Trash (emptying the Trash itself deletes for real). Returns bytes freed.
    static func clean(_ items: [CleanItem], home: URL) -> Int64 {
        let fm = FileManager.default
        var freed: Int64 = 0
        // Empty the Trash first so the items moved there below aren't deleted for good.
        for item in items.sorted(by: { $0.group == .trash && $1.group != .trash }) where allowed(item.url, home: home) {
            if item.group == .trash {
                for f in (try? fm.contentsOfDirectory(at: item.url, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: f) }
                freed += item.size
            } else if (try? fm.trashItem(at: item.url, resultingItemURL: nil)) != nil {
                freed += item.size
            }
        }
        return freed
    }
}

/// Finds an app's leftover files by its bundle id.
enum AppRemover {
    static let folders = ["Application Support", "Caches", "Preferences", "Containers", "Group Containers",
                          "Saved Application State", "HTTPStorages", "WebKit", "LaunchAgents"]

    /// Plain-words reason the app can't be removed, or nil if it can.
    static func refusal(app: URL, bundleID: String?, home: URL) -> String? {
        guard let id = bundleID, !id.isEmpty else { return "That doesn't look like an app." }
        if id.hasPrefix("com.apple.") { return "This app is part of macOS and can't be removed." }
        let parent = app.standardizedFileURL.deletingLastPathComponent().path
        guard app.pathExtension == "app", parent == "/Applications" || parent == home.appendingPathComponent("Applications").path else {
            return "Only apps in your Applications folder can be removed here."
        }
        return nil
    }

    static func matches(_ name: String, bundleID id: String, appName: String, folder: String) -> Bool {
        if name == id || name.hasPrefix(id + ".") { return true }
        if folder == "Group Containers" && name.hasSuffix("." + id) { return true }
        return (folder == "Application Support" || folder == "Caches") && name == appName
    }

    static func leftovers(bundleID: String, appName: String, home: URL) -> [URL] {
        folders.flatMap { folder -> [URL] in
            let dir = home.appendingPathComponent("Library").appendingPathComponent(folder)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            return names.filter { matches($0, bundleID: bundleID, appName: appName, folder: folder) }.map { dir.appendingPathComponent($0) }
        }
    }
}

@MainActor final class StorageModel: ObservableObject {
    static let shared = StorageModel()
    let home = FileManager.default.homeDirectoryForCurrentUser

    @Published var root: SizeNode?
    @Published var trail: [SizeNode] = []     // breadcrumb; last is the folder on screen
    @Published var scanning = false
    @Published var progress = 0.0
    @Published var bigFiles: [Hit] = []
    @Published var clean: [CleanItem] = []
    @Published var selected: Set<String> = []
    @Published var app: URL?
    @Published var appLeftovers: [CleanItem] = []
    @Published var appMessage = ""

    var current: SizeNode? { trail.last ?? root }
    var selectedBytes: Int64 { clean.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size } }

    func scan() {
        guard !scanning else { return }
        scanning = true; progress = 0
        let start = hasFullDiskAccess() ? URL(fileURLWithPath: "/") : home
        Task.detached(priority: .utility) {
            let big = BigFiles()
            let node = SpaceScan.scan(start, big: big) { p in Task { @MainActor in StorageModel.shared.progress = p } }
            let files = big.hits.sorted { $0.size > $1.size }.prefix(200).map { $0 }
            await MainActor.run {
                let m = StorageModel.shared
                m.root = node; m.trail = []; m.bigFiles = files; m.scanning = false
            }
        }
    }

    func loadCleanup() {
        let home = home
        Task.detached(priority: .utility) {
            var items = Cleanup.candidates(home: home)
            for i in items.indices { items[i].size = FileManager.default.size(of: items[i].url) }
            let kept = items.filter { $0.size >= 1_000_000 }.sorted { $0.size > $1.size }
            await MainActor.run {
                let m = StorageModel.shared
                m.clean = kept
                // Precious or permanent things start unticked.
                m.selected = Set(kept.filter { $0.group != .trash && $0.group != .backups }.map(\.id))
            }
        }
    }

    func runCleanup() {
        let chosen = clean.filter { selected.contains($0.id) }, home = home
        Task.detached(priority: .userInitiated) {
            let freed = Cleanup.clean(chosen, home: home)
            await MainActor.run {
                if freed > 0 { Store.log("Freed \(bytes(freed))", saved: freed) }
                StorageModel.shared.loadCleanup()
            }
        }
    }

    func trash(_ hit: Hit) {
        if (try? FileManager.default.trashItem(at: URL(fileURLWithPath: hit.path), resultingItemURL: nil)) != nil {
            bigFiles.removeAll { $0.path == hit.path }
        }
    }

    func pickApp(_ url: URL) {
        app = nil; appLeftovers = []; appMessage = ""
        let bundle = Bundle(url: url)
        if let no = AppRemover.refusal(app: url, bundleID: bundle?.bundleIdentifier, home: home) { appMessage = no; return }
        guard let id = bundle?.bundleIdentifier else { return }
        app = url
        let name = url.deletingPathExtension().lastPathComponent, home = home
        Task.detached {
            let items = ([url] + AppRemover.leftovers(bundleID: id, appName: name, home: home)).map {
                CleanItem(url: $0, group: .caches, label: $0 == url ? name : $0.deletingLastPathComponent().lastPathComponent + " · " + $0.lastPathComponent,
                          size: FileManager.default.size(of: $0))
            }
            await MainActor.run { StorageModel.shared.appLeftovers = items }
        }
    }

    func removeApp() {
        guard let app else { return }
        if let id = Bundle(url: app)?.bundleIdentifier, !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty {
            appMessage = "Quit \(app.deletingPathExtension().lastPathComponent) first, then try again."
            return
        }
        var freed: Int64 = 0
        for item in appLeftovers where (try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)) != nil { freed += item.size }
        Store.log("Removed \(app.deletingPathExtension().lastPathComponent) · freed \(bytes(freed))", saved: freed)
        self.app = nil; appLeftovers = []
        appMessage = "Moved to the Trash."
    }
}
