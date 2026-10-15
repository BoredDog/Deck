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
                            status: d["status"] as? String ?? "waiting", file: file)
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
        port = Int.random(in: 20000...60000)
        secret = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path
        var args = ["--enable-rpc", "--rpc-listen-all=false", "--rpc-listen-port=\(port)", "--rpc-secret=\(secret)",
                    "--stop-with-process=\(getpid())", "--continue=true", "-x16", "-s16", "-k1M",
                    "--dir", downloadsDir, "--save-session=\(sessionFile.path)", "--save-session-interval=10",
                    "--enable-dht=false", "--enable-peer-exchange=false", "--bt-enable-lpd=false", "--quiet"]
        if FileManager.default.fileExists(atPath: sessionFile.path) { args.append("--input-file=\(sessionFile.path)") }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        // shortcut: a port clash (1 in 40,000) just means no downloads until the next launch; retry if it ever shows up.
        do { try p.run() } catch { return }
        process = p
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.refresh()
            }
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
        if new != items { items = new }
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
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(C.border, lineWidth: 0.5))
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
        default:
            let left = item.timeLeft.map { Duration.seconds($0).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)) }
            return "\(bytes(item.speed))/s" + (left.map { " · \($0) left" } ?? "")
        }
    }
}
