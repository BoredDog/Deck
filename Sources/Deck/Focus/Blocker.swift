import SwiftUI
import AppKit
import ServiceManagement
import os

/// Keeps chosen apps and websites out of the way during focus.
@MainActor final class Blocker {
    static let shared = Blocker()
    private var allowUntil = Date.distantPast
    private var panel: NSPanel?

    private static let hosts = "/etc/hosts"
    private static let flush = "dscacheutil -flushcache; killall -HUP mDNSResponder"

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { Blocker.shared.activated(app) }
        }
    }

    static func list(_ key: String) -> [String] {
        (UserDefaults.standard.string(forKey: key) ?? "").split(separator: "\n").map(String.init)
    }

    // MARK: apps

    private func activated(_ app: NSRunningApplication?) {
        guard FocusTimer.shared.focusing, Date.now > allowUntil, let app, let id = app.bundleIdentifier,
              Self.list(FocusKey.apps).contains(id) else { return }
        app.hide()
        showCard(for: app)
    }

    private func showCard(for app: NSRunningApplication) {
        panel?.close()
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 160),
                        styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.level = .floating
        let card = BackToFocusCard(appName: app.localizedName ?? "That app",
            back: { [weak p] in p?.close() },
            fiveMore: { [weak self, weak p] in
                self?.allowUntil = .now + 300
                p?.close()
                app.unhide()
                app.activate()
            })
            .environment(\.accent, Accent.named(UserDefaults.standard.string(forKey: "theme") ?? ""))
            .preferredColorScheme(.dark)
        p.contentView = NSHostingView(rootView: card)
        p.center()
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        panel = p
    }

    // MARK: websites

    /// Keeps only plain domain names ("youtube.com"), so nothing else can reach the admin shell command.
    nonisolated static func validDomains(_ raw: [String]) -> [String] {
        raw.compactMap { s in
            var d = s.lowercased().trimmingCharacters(in: .whitespaces)
            if let host = URL(string: d.contains("://") ? d : "http://\(d)")?.host { d = host }
            if d.hasPrefix("www.") { d.removeFirst(4) }
            guard d.range(of: "^[a-z0-9.-]+$", options: .regularExpression) != nil,
                  d.contains("."), !d.hasPrefix("."), !d.hasPrefix("-") else { return nil }
            return d
        }
    }

    private var currentHosts: String? { try? String(contentsOfFile: Self.hosts, encoding: .utf8) }

    /// Adds a marked block to /etc/hosts: silently through the helper once it's set up, otherwise with one password prompt.
    func blockSites() {
        let domains = Self.validDomains(Self.list(FocusKey.sites))
        guard !domains.isEmpty else { return }
        if callHelper({ $0.block(domains, reply: $1) }) { return }
        guard let current = currentHosts, let new = HostsFile.addingBlock(current, domains: domains) else { return }
        admin(writing: new, prompt: "Deck needs your password to block distracting websites while you focus.")
    }

    func unblockSites() {
        guard let current = currentHosts, current.contains(HostsFile.start) else { return }
        if callHelper({ $0.unblock(reply: $1) }) { return }
        admin(writing: HostsFile.removingBlock(current), prompt: "Deck needs your password to unblock websites.")
    }

    /// A crash or force-quit mid-session can leave sites blocked; remove them on the next launch.
    func cleanUpLeftovers() {
        DispatchQueue.main.async { if !FocusTimer.shared.running { self.unblockSites() } }
    }

    /// Fallback when the helper isn't set up: writes the new /etc/hosts from a temp file through the admin password prompt.
    /// Runs in its own process, so Deck never waits for it (not even at quit).
    private func admin(writing hosts: String, prompt: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deck-hosts-\(UUID().uuidString)")
        let file = dir.appendingPathComponent("hosts")
        guard Self.isOurTempFile(file.path),
              (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)) != nil,
              (try? hosts.write(to: file, atomically: false, encoding: .utf8)) != nil else { return }
        // `cat >` keeps /etc/hosts' owner and permissions. The paths were checked: no quotes or spaces to escape.
        let shell = "cat '\(file.path)' > \(Self.hosts); rm -rf '\(dir.path)'; \(Self.flush)"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "do shell script \"\(shell)\" with prompt \"\(prompt)\" with administrator privileges"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) == nil { try? FileManager.default.removeItem(at: dir) }
    }

    /// Only a file Deck just made in its own temp folder, with nothing in the path a shell could misread.
    nonisolated static func isOurTempFile(_ path: String) -> Bool {
        let tmp = FileManager.default.temporaryDirectory.standardizedFileURL.path
        return path.hasPrefix(tmp + (tmp.hasSuffix("/") ? "" : "/") + "deck-hosts-") && !path.contains("..")
            && path.range(of: "^[A-Za-z0-9/._-]+$", options: .regularExpression) != nil
    }

    // MARK: helper (one-time setup, then no password)

    static let helper = SMAppService.daemon(plistName: "com.nav.deck.helper.plist")

    /// Registers the helper; macOS then asks the user to allow it in Login Items.
    static func setUpHelper() {
        do { try helper.register() } catch { NSLog("Deck helper register: \(error)") }
        if helper.status != .enabled { SMAppService.openSystemSettingsLoginItems() }
    }

    /// Runs one helper call and waits up to 3 seconds for its answer. False means "use the password prompt instead".
    private func callHelper(_ call: (DeckHelperProtocol, @escaping (Bool) -> Void) -> Void) -> Bool {
        guard Self.helper.status == .enabled else { return false }
        let c = NSXPCConnection(machServiceName: "com.nav.deck.helper", options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: DeckHelperProtocol.self)
        c.resume()
        defer { c.invalidate() }
        let done = DispatchSemaphore(value: 0)
        let result = OSAllocatedUnfairLock(initialState: false)
        guard let proxy = c.remoteObjectProxyWithErrorHandler({ _ in done.signal() }) as? DeckHelperProtocol else { return false }
        call(proxy) { ok in result.withLock { $0 = ok }; done.signal() }
        return done.wait(timeout: .now() + 3) == .success && result.withLock { $0 }
    }
}

/// Must match the helper's protocol (Sources/DeckHelper/main.swift) selector for selector.
@objc(DeckHelperProtocol) protocol DeckHelperProtocol {
    func block(_ domains: [String], reply: @escaping (Bool) -> Void)
    func unblock(reply: @escaping (Bool) -> Void)
}

private struct BackToFocusCard: View {
    let appName: String
    let back: () -> Void
    let fiveMore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Back to focus?").font(F.ui(18, medium: true))
            Text("\(appName) is resting until your session ends.").font(F.body).foregroundStyle(C.text2)
            HStack(spacing: 8) {
                Button("Back to focus", action: back).buttonStyle(.primary)
                Button("Just 5 minutes", action: fiveMore).buttonStyle(.pill)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(C.bg)
        .foregroundStyle(C.text)
    }
}
