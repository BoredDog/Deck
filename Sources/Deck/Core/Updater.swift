import SwiftUI

/// Updates Deck from GitHub. Two ways, always asking first:
/// - Built from the project folder (scripts/bundle.sh): fetch `main`, and when there are new commits, pull, rebuild and relaunch.
/// - Installed from the DMG: check the latest GitHub Release, download its .dmg to Downloads and open it.
@MainActor final class Updater: ObservableObject {
    static let shared = Updater()

    enum State: Equatable { case idle, checking, upToDate, available([String]), updating(String), downloaded, failed(String) }

    @AppStorage("updatesOn") var enabled = true { didSet { schedule() } }
    @Published var state = State.idle
    @Published var progress = 0.0
    private var timer: Timer?
    private var announced: String?

    /// Written into Info.plist by scripts/bundle.sh: where the project lives and which commit this build is.
    private let source = Bundle.main.object(forInfoDictionaryKey: "DeckSourcePath") as? String
    private let built = Bundle.main.object(forInfoDictionaryKey: "DeckCommit") as? String
    var fromSource: Bool { source != nil && built != nil }

    struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        let tag_name: String
        let name: String?
        let body: String?
        let assets: [Asset]
    }
    private var release: Release?
    private var watch: NSKeyValueObservation?
    private static let session = URLSession(configuration: .ephemeral)   // no cookies, no cache on disk
    private static let latest = URL(string: "https://api.github.com/repos/BoredDog/Deck/releases/latest")!

    func start() {
        schedule()
        Task { try? await Task.sleep(for: .seconds(60)); if enabled { await check() } }
    }

    private func schedule() {
        timer?.invalidate()
        guard enabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in Task { await Updater.shared.check() } }
    }

    private func git(_ args: [String]) async throws -> String {
        try await Engine.run("git", ["-C", source!] + args, offline: false).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func check() async {
        guard !isBusy else { return }
        state = .checking
        guard fromSource else { return await checkRelease() }
        do {
            try await git(["fetch", "--quiet", "origin", "main"])
            let log = try await git(["log", "--format=%s", "\(built!)..origin/main"])
            let changes = log.split(separator: "\n").map(String.init)
            state = changes.isEmpty ? .upToDate : .available(changes)
            let head = try await git(["rev-parse", "origin/main"])
            if !changes.isEmpty, announced != head {
                announced = head
                Store.log("A Deck update is ready: \(changes.count) change\(changes.count == 1 ? "" : "s"). Open Settings to update.", kind: "info")
            }
        } catch {
            state = .failed("Couldn't reach GitHub. Deck will try again later.")
        }
    }

    /// "v1.10" vs "1.9.2": numbers compared part by part, missing parts count as 0 (1.2 == 1.2.0).
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.trimmingCharacters(in: .whitespaces).drop { $0 == "v" || $0 == "V" }
                .split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private func checkRelease() async {
        do {
            var req = URLRequest(url: Self.latest)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, resp) = try await Self.session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { state = .upToDate; return }   // no releases yet
            guard code == 200 else { throw URLError(.badServerResponse) }
            let r = try JSONDecoder().decode(Release.self, from: data)
            let mine = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            guard Self.isNewer(r.tag_name, than: mine), r.assets.contains(where: { $0.name.hasSuffix(".dmg") }) else {
                state = .upToDate; return
            }
            release = r
            let notes = (r.body ?? "").split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-*# ")) }.filter { !$0.isEmpty }
            state = .available([r.name ?? "Deck \(r.tag_name)"] + notes.prefix(5))
            if announced != r.tag_name {
                announced = r.tag_name
                Store.log("Deck \(r.tag_name) is out. Open Settings to download it.", kind: "info")
            }
        } catch {
            state = .failed("Couldn't reach GitHub. Deck will try again later.")
        }
    }

    /// Downloads the release's .dmg into Downloads and opens it; the person drags the new Deck into Applications.
    func download() async {
        guard !isBusy, let asset = release?.assets.first(where: { $0.name.hasSuffix(".dmg") }) else { return }
        state = .updating("Downloading \(asset.name)…")
        progress = 0
        let dest = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent(asset.name)
        do {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                let task = Self.session.downloadTask(with: asset.browser_download_url) { tmp, resp, error in
                    // The temporary file is deleted when this returns, so move it now.
                    guard let tmp, (resp as? HTTPURLResponse)?.statusCode == 200 else {
                        return done.resume(throwing: error ?? URLError(.badServerResponse))
                    }
                    do {
                        try? FileManager.default.removeItem(at: dest)
                        try FileManager.default.moveItem(at: tmp, to: dest)
                        done.resume()
                    } catch { done.resume(throwing: error) }
                }
                watch = task.progress.observe(\.fractionCompleted) { p, _ in
                    let f = p.fractionCompleted
                    Task { @MainActor in Updater.shared.progress = f }
                }
                task.resume()
            }
            watch = nil
            NSWorkspace.shared.open(dest)
            state = .downloaded
        } catch {
            watch = nil
            state = .failed("The download didn't finish. Deck is unchanged.")
        }
    }

    private var isBusy: Bool { if case .updating = state { true } else { false } }

    /// Why updating now would interrupt something, if anything.
    var blocker: String? {
        if FocusTimer.shared.focusing { return "Finish your focus session first." }
        if Downloads.shared.items.contains(where: { ["active", "waiting"].contains($0.status) }) { return "Wait for downloads to finish." }
        if Setup.shared.busyAddOn != nil || Setup.shared.working { return "Wait for the install to finish." }
        return nil
    }

    func update() async {
        guard fromSource, !isBusy, blocker == nil else { return }
        do {
            state = .updating("Getting the changes…")
            // ff-only: never merges over work in the project folder.
            try await git(["pull", "--ff-only", "--quiet", "origin", "main"])
            state = .updating("Building the update… (a minute or two)")
            try await Engine.run("zsh", ["\(source!)/scripts/bundle.sh"], cwd: URL(fileURLWithPath: source!), offline: false)
            state = .updating("Restarting…")
            // Reopen the new build after this one quits.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 2; /usr/bin/open /Applications/Deck.app"]
            try p.run()
            NSApp.terminate(nil)
        } catch {
            state = .failed("The update didn't finish. Deck is unchanged. (The project folder may have changes of its own.)")
        }
    }
}

struct UpdateSettings: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Tile {
            TileLabel(text: "Updates")
            Toggle("Check GitHub for updates", isOn: $updater.enabled).toggleStyle(.switch).font(F.body)
            switch updater.state {
            case .idle, .upToDate:
                HStack {
                    Text(updater.state == .upToDate ? "You're up to date." : "Checks every 6 hours.").font(F.label).foregroundStyle(C.text2)
                    Spacer()
                    Button("Check now") { Task { await updater.check() } }.buttonStyle(.pill)
                }
            case .checking:
                Text("Checking…").font(F.label).foregroundStyle(C.text2)
            case .available(let changes) where !updater.fromSource:
                Text("\(changes[0]) is out").font(F.body)
                ForEach(changes.dropFirst(), id: \.self) { Text("· \($0)").font(F.label).foregroundStyle(C.text2).lineLimit(1) }
                Button("Download update") { Task { await updater.download() } }.buttonStyle(.pill)
            case .available(let changes):
                Text("Update ready: \(changes.count) change\(changes.count == 1 ? "" : "s")").font(F.body)
                ForEach(changes.prefix(5), id: \.self) { Text("· \($0)").font(F.label).foregroundStyle(C.text2).lineLimit(1) }
                if let why = updater.blocker {
                    Text(why).font(F.label).foregroundStyle(C.warn)
                }
                Button("Update and restart") { Task { await updater.update() } }
                    .buttonStyle(.pill).disabled(updater.blocker != nil)
            case .updating(let step):
                Text(step).font(F.body).foregroundStyle(C.text2)
                if !updater.fromSource { Bar4(value: updater.progress) }
            case .downloaded:
                Text("Drag the new Deck into Applications to replace the old one.")
                    .font(F.body).foregroundStyle(C.text2).fixedSize(horizontal: false, vertical: true)
            case .failed(let why):
                HStack {
                    Text(why).font(F.label).foregroundStyle(C.warn).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Try again") { Task { await updater.check() } }.buttonStyle(.pill)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
