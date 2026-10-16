import SwiftUI
import AppKit

struct DownloadItem: Identifiable, Equatable {
    let id: String          // aria2 gid
    var name: String
    var total: Int64
    var done: Int64
    var speed: Int64        // bytes per second
    var status: String      // "active", "waiting", "paused", "complete", "error", "removed"
    var file: URL? = nil    // where it lands, for "Show in Finder"
    var findingSources = false  // a magnet link still fetching its file list from other people
    var progress: Double { total > 0 ? Double(done) / Double(total) : 0 }
    /// Seconds left at the current speed, nil when unknown.
    var timeLeft: Int64? { speed > 0 && total > done ? (total - done) / speed : nil }

    /// Reads one aria2 status dictionary. Returns nil for torrent-metadata stubs that hand off to the real download.
    static func parse(_ d: [String: Any]) -> DownloadItem? {
        guard let gid = d["gid"] as? String else { return nil }
        if let next = d["followedBy"] as? [Any], !next.isEmpty { return nil }
        func n(_ k: String) -> Int64 { Int64(d[k] as? String ?? "") ?? 0 }
        let files = d["files"] as? [[String: Any]] ?? []
        let firstPath = files.first?["path"] as? String ?? ""
        let uri = ((files.first?["uris"] as? [[String: Any]])?.first?["uri"] as? String).flatMap(URL.init(string:))
        let torrentName = ((d["bittorrent"] as? [String: Any])?["info"] as? [String: Any])?["name"] as? String
        let dir = d["dir"] as? String ?? ""

        var file: URL? = firstPath.isEmpty ? nil : URL(fileURLWithPath: firstPath)
        if let torrentName, files.count > 1, !dir.isEmpty { file = URL(fileURLWithPath: dir).appendingPathComponent(torrentName) }
        let name = torrentName ?? file?.lastPathComponent ?? uri?.lastPathComponent ?? "Download"

        return DownloadItem(id: gid, name: name.isEmpty || name == "/" ? (uri?.host ?? "Download") : name,
                            total: n("totalLength"), done: n("completedLength"), speed: n("downloadSpeed"),
                            status: d["status"] as? String ?? "waiting", file: file,
                            findingSources: firstPath.hasPrefix("[METADATA]") || (d["bittorrent"] != nil && torrentName == nil))
    }
}

@MainActor final class Downloads: ObservableObject {
    static let shared = Downloads()
    @Published var items: [DownloadItem] = []
    /// Plain-words problem to show, e.g. a link that isn't a link.
    @Published var message = ""

    private var process: Process?
    private var port = 0
    private var secret = ""
    private var poller: Task<Void, Never>?
    private var logged: Set<String> = []
    /// When each magnet link started looking for its file list.
    private var askedAt: [String: Date] = [:]
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:] // the RPC token must never go through a proxy
        c.timeoutIntervalForRequest = 3
        return URLSession(configuration: c)
    }()

    var running: Bool { process?.isRunning == true }
    var sessionFile: URL { Vault.folder.appendingPathComponent("downloads.session") }

    func start() {
        guard !running, let exe = Engine.path("aria2c") else { return }
        // A taken port means no downloads, so try up to 3 more random ports before giving up on checking.
        port = (0..<4).lazy.map { _ in Int.random(in: 20000...60000) }.first(where: Self.portFree) ?? Int.random(in: 20000...60000)
        secret = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path
        var args = ["--enable-rpc", "--rpc-listen-all=false", "--rpc-listen-port=\(port)", "--rpc-secret=\(secret)",
                    "--stop-with-process=\(getpid())", "--continue=true", "-x16", "-s16", "-k1M",
                    "--dir", downloadsDir, "--save-session=\(sessionFile.path)", "--save-session-interval=10",
                    "--enable-dht=false", "--enable-peer-exchange=false", "--bt-enable-lpd=false", "--seed-time=0", "--quiet"]
        if FileManager.default.fileExists(atPath: sessionFile.path) { args.append("--input-file=\(sessionFile.path)") }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return }
        process = p
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.refresh()
            }
        }
    }

    /// True if nothing on this Mac is listening on the port yet.
    nonisolated static func portFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    func stop() {
        poller?.cancel()
        guard running, let p = process else { return }
        // Called while the app quits, so wait (briefly) for the queue to be written before stopping the engine.
        let done = DispatchSemaphore(value: 0)
        if let req = request("aria2.saveSession", []) {
            session.dataTask(with: req) { _, _, _ in done.signal() }.resume()
            _ = done.wait(timeout: .now() + 2)
        }
        p.terminate()
        process = nil
    }

    func add(_ link: String) {
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = URL(string: link)?.scheme?.lowercased(), ["http", "https", "ftp", "sftp", "magnet"].contains(scheme) else {
            message = "That doesn't look like a download link."
            return
        }
        message = ""
        start()
        Task { await call("aria2.addUri", [[link]], retry: true) }
    }

    /// A dropped .torrent or .metalink file.
    func add(file url: URL) {
        let ext = url.pathExtension.lowercased()
        guard ["torrent", "metalink", "meta4"].contains(ext), let data = try? Data(contentsOf: url) else {
            message = "Drop a torrent or metalink file here, or paste a link above."
            return
        }
        message = ""
        start()
        Task { await call(ext == "torrent" ? "aria2.addTorrent" : "aria2.addMetalink", [data.base64EncodedString()], retry: true) }
    }

    func pause(_ item: DownloadItem) { Task { await call("aria2.pause", [item.id]); await refresh() } }
    func resume(_ item: DownloadItem) { Task { await call("aria2.unpause", [item.id]); await refresh() } }

    func remove(_ item: DownloadItem) {
        let stopped = ["complete", "error", "removed"].contains(item.status)
        Task { await call(stopped ? "aria2.removeDownloadResult" : "aria2.remove", [item.id]); await refresh() }
    }

    func clearFinished() { Task { await call("aria2.purgeDownloadResult", []); await refresh() } }

    func refresh() async {
        let keys = ["gid", "status", "totalLength", "completedLength", "downloadSpeed", "files", "bittorrent", "dir", "followedBy"]
        let calls: [[String: Any]] = [
            ["methodName": "aria2.tellActive", "params": ["token:\(secret)", keys]],
            ["methodName": "aria2.tellWaiting", "params": ["token:\(secret)", 0, 1000, keys]],
            ["methodName": "aria2.tellStopped", "params": ["token:\(secret)", 0, 1000, keys]],
        ]
        // multicall takes no top-level token; each inner call carries its own.
        guard let result = await call("system.multicall", [calls], token: false) as? [[Any]] else { return }
        let new = result.flatMap { ($0.first as? [[String: Any]]) ?? [] }.compactMap(DownloadItem.parse)
        for item in new where item.status == "complete" && !logged.contains(item.id) {
            logged.insert(item.id)
            Store.log("Downloaded \(item.name)", kind: "download", file: item.file)
        }
        // Magnet links with nobody sharing them would wait forever: say so after a minute, give up after three.
        for item in new where item.findingSources && item.status == "active" {
            let since = askedAt[item.id] ?? .now
            askedAt[item.id] = since
            if Date.now.timeIntervalSince(since) > 180 {
                await call("aria2.remove", [item.id])
                message = "Couldn't find anyone sharing that magnet link. Try again later, or use a .torrent file."
            }
        }
        if new != items { items = new }
    }

    func lookingForSources(_ item: DownloadItem) -> Bool {
        item.findingSources && item.status == "active" && askedAt[item.id].map { Date.now.timeIntervalSince($0) > 60 } == true
    }

    @discardableResult
    private func call(_ method: String, _ params: [Any], token: Bool = true, retry: Bool = false) async -> Any? {
        guard let req = request(method, params, token: token) else { return nil }
        // A just-launched engine needs a moment before it listens; only retry when the connection itself failed.
        for _ in 0..<(retry ? 10 : 1) {
            if let (data, _) = try? await session.data(for: req) {
                return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["result"]
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return nil
    }

    private func request(_ method: String, _ params: [Any], token: Bool = true) -> URLRequest? {
        guard running, let url = URL(string: "http://127.0.0.1:\(port)/jsonrpc") else { return nil }
        let body: [String: Any] = ["jsonrpc": "2.0", "id": "deck", "method": method,
                                   "params": token ? ["token:\(secret)"] + params : params]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }
}

struct DownloadsView: View {
    @ObservedObject private var downloads = Downloads.shared
    @State private var link = ""
    @State private var hasEngine = Engine.has("aria2c")

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScreenHeader(title: "Downloads", subtitle: "Paste a link and it downloads fast. It picks up where it left off, even after you quit.")
            if !hasEngine {
                SetupCard()
            } else {
                Tile {
                    HStack(spacing: 8) {
                        TextField("Paste a link", text: $link)
                            .textFieldStyle(.plain).font(F.ui(14))
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(C.bg))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(C.border, lineWidth: 1))
                            .onSubmit(download)
                        Button("Download", action: download).buttonStyle(.primary).disabled(link.isEmpty)
                    }
                    if !downloads.message.isEmpty { Text(downloads.message).font(F.label).foregroundStyle(C.warn) }
                }
                .fixedSize(horizontal: false, vertical: true)
                DropZone(prompt: "Drop a torrent or metalink file", allowFolders: false) { urls in
                    urls.forEach(downloads.add(file:))
                }
                list
            }
            if case let addOn = Setup.addOn("videolinks") {
                if Setup.installed(addOn) {
                    VideoLinkTile()
                } else {
                    Tile {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Save video from a link").font(F.body)
                                Text(addOn.detail).font(F.label).foregroundStyle(C.text2)
                            }
                            Spacer()
                            AddOnButton(addOn: addOn)
                        }
                    }
                    .frame(height: 70)
                }
            }
        }
        .onAppear {
            hasEngine = Engine.has("aria2c")
            downloads.start()
        }
    }

    @ViewBuilder private var list: some View {
        if !downloads.items.isEmpty {
            Tile {
                HStack {
                    TileLabel(text: "Downloads")
                    Spacer()
                    if downloads.items.contains(where: { $0.status != "active" && $0.status != "waiting" && $0.status != "paused" }) {
                        Button("Clear finished", action: downloads.clearFinished).buttonStyle(.pill)
                    }
                }
                ForEach(downloads.items) { item in
                    DownloadRow(item: item, last: item.id == downloads.items.last?.id)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func download() {
        downloads.add(link)
        if downloads.message.isEmpty { link = "" }
    }
}

/// Shown only when the "Save video from a link" add-on is on. Saves into Downloads.
private struct VideoLinkTile: View {
    @State private var link = ""
    @State private var audioOnly = false
    @State private var progress: Double?
    @State private var message = ""

    var body: some View {
        Tile {
            TileLabel(text: "Save video from a link")
            Text("Only for videos you have the right to download.").font(F.label).foregroundStyle(C.text2)
            HStack(spacing: 8) {
                TextField("Paste the page link", text: $link)
                    .textFieldStyle(.plain).font(F.ui(14))
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(C.bg))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(C.border, lineWidth: 1))
                    .onSubmit(save)
                PillPicker(selection: $audioOnly, options: [("Video", false), ("Audio", true)])
                Button("Save", action: save).buttonStyle(.pill).disabled(link.isEmpty || progress != nil)
            }
            if let progress { Bar4(value: progress) }
            if !message.isEmpty { Text(message).font(F.label).foregroundStyle(C.text2) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func save() {
        let l = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = URL(string: l)?.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            message = "That doesn't look like a link."
            return
        }
        message = ""
        progress = 0
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        Task { @MainActor in
            do {
                let file = try await VideoLink.download(l, audioOnly: audioOnly, into: folder) { p in
                    Task { @MainActor in if progress != nil { progress = p } }
                }
                Store.log("Saved \(file.lastPathComponent)", kind: "download", file: file)
                message = "Saved \(file.lastPathComponent) to Downloads."
                link = ""
            } catch {
                message = "Couldn't save that one. Check the link and try again."
            }
            progress = nil
        }
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    let last: Bool
    @ObservedObject private var downloads = Downloads.shared

    var body: some View {
        Row(divider: !last) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.name).font(F.ui(13, medium: true)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(detail).font(F.mono(11)).foregroundStyle(item.status == "error" ? C.warn : C.text2)
                }
                Bar4(value: item.status == "complete" ? 1 : item.progress)
            }
            switch item.status {
            case "active", "waiting": Button("Pause") { downloads.pause(item) }.buttonStyle(.pill)
            case "paused": Button("Resume") { downloads.resume(item) }.buttonStyle(.pill)
            case "complete":
                if let file = item.file {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }.buttonStyle(.pill)
                }
            default: EmptyView()
            }
            Button("Remove") { downloads.remove(item) }.buttonStyle(.pill)
        }
    }

    private var detail: String {
        switch item.status {
        case "complete": return "done · \(bytes(item.total))"
        case "paused": return "paused · \(bytes(item.done)) of \(bytes(item.total))"
        case "waiting": return "waiting"
        case "error": return "couldn't finish"
        case "removed": return "stopped"
        case _ where downloads.lookingForSources(item): return "Looking for sources…"
        default:
            let left = item.timeLeft.map { Duration.seconds($0).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)) }
            return "\(bytes(item.speed))/s" + (left.map { " · \($0) left" } ?? "")
        }
    }
}
