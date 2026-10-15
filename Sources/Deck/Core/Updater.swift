import SwiftUI

/// Updates Deck from GitHub by rebuilding on this Mac: fetch the project folder's `main`, and when there are new
/// commits, pull, run scripts/bundle.sh (which signs with your Apple ID) and relaunch. Always asks first.
@MainActor final class Updater: ObservableObject {
    static let shared = Updater()

    enum State: Equatable { case idle, checking, upToDate, available([String]), updating(String), failed(String) }

    @AppStorage("updatesOn") var enabled = true { didSet { schedule() } }
    @Published var state = State.idle
    private var timer: Timer?
    private var announced: String?

    /// Written into Info.plist by scripts/bundle.sh: where the project lives and which commit this build is.
    private let source = Bundle.main.object(forInfoDictionaryKey: "DeckSourcePath") as? String
    private let built = Bundle.main.object(forInfoDictionaryKey: "DeckCommit") as? String
    var available: Bool { source != nil && built != nil }

    func start() {
        schedule()
        Task { try? await Task.sleep(for: .seconds(60)); if enabled { await check() } }
    }

    private func schedule() {
        timer?.invalidate()
        guard enabled, available else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in Task { await Updater.shared.check() } }
    }

    private func git(_ args: [String]) async throws -> String {
        try await Engine.run("git", ["-C", source!] + args, offline: false).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func check() async {
        guard available, !isBusy else { return }
        state = .checking
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

    private var isBusy: Bool { if case .updating = state { true } else { false } }

    /// Why updating now would interrupt something, if anything.
    var blocker: String? {
        if FocusTimer.shared.focusing { return "Finish your focus session first." }
        if Downloads.shared.items.contains(where: { ["active", "waiting"].contains($0.status) }) { return "Wait for downloads to finish." }
        if Setup.shared.busyAddOn != nil || Setup.shared.working { return "Wait for the install to finish." }
        return nil
    }

    func update() async {
        guard available, !isBusy, blocker == nil else { return }
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
            if !updater.available {
                Text("Updates work when Deck is built from its project folder with scripts/bundle.sh.")
                    .font(F.body).foregroundStyle(C.text2).fixedSize(horizontal: false, vertical: true)
            } else {
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
                case .failed(let why):
                    HStack {
                        Text(why).font(F.label).foregroundStyle(C.warn).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Try again") { Task { await updater.check() } }.buttonStyle(.pill)
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
