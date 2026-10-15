import Foundation
import Security
import SystemConfiguration

// DeckHelper: a root launchd daemon (installed once with SMAppService) that blocks websites during focus
// and controls the fans. It can write Deck's marked block into /etc/hosts, remove it, and set or release fans
// (SMCWrite.swift). Nothing else.

@objc(DeckHelperProtocol) protocol DeckHelperProtocol {
    func block(_ domains: [String], reply: @escaping (Bool) -> Void)
    func unblock(reply: @escaping (Bool) -> Void)
    func setFan(index: Int, rpm: Int, reply: @escaping (Bool) -> Void)
    func setFanAuto(index: Int, reply: @escaping (Bool) -> Void)
    func resetAllFans(reply: @escaping (Bool) -> Void)
}

final class Helper: NSObject, DeckHelperProtocol, NSXPCListenerDelegate {
    private let hosts = URL(fileURLWithPath: "/etc/hosts")
    private let lock = NSLock()
    /// All SMC work and the client list live on this queue.
    private let fans = DispatchQueue(label: "com.nav.deck.helper.fans")
    /// Open connections, held strongly until they close so an identifier can't be reused by a new one meanwhile.
    private var clients: [ObjectIdentifier: NSXPCConnection] = [:]

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        // Only the exact Deck build this helper ships inside, run by the person at the screen.
        guard let requirement = appRequirement(), c.effectiveUserIdentifier == consoleUser() else { return false }
        c.setCodeSigningRequirement(requirement)
        let iface = NSXPCInterface(with: DeckHelperProtocol.self)
        iface.setClasses(NSSet(objects: NSArray.self, NSString.self) as! Set<AnyHashable>, for: #selector(DeckHelperProtocol.block(_:reply:)), argumentIndex: 0, ofReply: false)
        c.exportedInterface = iface
        c.exportedObject = self
        let id = ObjectIdentifier(c)
        fans.sync { clients[id] = c }
        // Safety: when the last client goes away (Deck quit or crashed), forced fans go back to automatic.
        let gone = { [weak self] in
            guard let self else { return }
            self.fans.async {
                guard self.clients.removeValue(forKey: id) != nil, self.clients.isEmpty, FanControl.touched else { return }
                FanControl.resetAll()
            }
        }
        c.invalidationHandler = gone
        c.interruptionHandler = gone
        c.resume()
        return true
    }

    func block(_ domains: [String], reply: @escaping (Bool) -> Void) {
        reply(edit { HostsFile.addingBlock($0, domains: domains) })
    }

    func unblock(reply: @escaping (Bool) -> Void) {
        reply(edit { HostsFile.removingBlock($0) })
    }

    func setFan(index: Int, rpm: Int, reply: @escaping (Bool) -> Void) {
        fans.async { reply(FanControl.set(index, rpm: rpm)) }
    }

    func setFanAuto(index: Int, reply: @escaping (Bool) -> Void) {
        fans.async { reply(FanControl.auto(index)) }
    }

    func resetAllFans(reply: @escaping (Bool) -> Void) {
        fans.async { reply(FanControl.resetAll()) }
    }

    /// The designated requirement of the app this helper lives in (<App>.app/Contents/MacOS/DeckHelper), read fresh each
    /// time so an updated Deck still connects. Ad-hoc signed, that's the app's exact code hash. Nil means refuse everyone.
    private func appRequirement() -> String? {
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var code: SecStaticCode?, req: SecRequirement?, text: CFString?
        guard app.pathExtension == "app",
              SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopyDesignatedRequirement(code, [], &req) == errSecSuccess, let req,
              SecRequirementCopyString(req, [], &text) == errSecSuccess else { return nil }
        return text as String?
    }

    /// Who's logged in at the screen; nobody (or the login window) means no one may connect.
    private func consoleUser() -> uid_t? {
        var uid: uid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String?, name != "loginwindow" else { return nil }
        return uid
    }

    /// Reads /etc/hosts, applies `change`, writes it back atomically and flushes DNS. Never writes if the read failed.
    private func edit(_ change: (String) -> String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let old = try? String(contentsOf: hosts, encoding: .utf8), let new = change(old) else { return false }
        if new != old {
            guard (try? new.write(to: hosts, atomically: true, encoding: .utf8)) != nil else { return false }
            _ = try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: hosts.path)
        }
        run("/usr/bin/dscacheutil", ["-flushcache"])
        run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
        return true
    }

    private func run(_ exe: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }
}

// A helper that crashed while a fan was forced hands the fans back before doing anything else.
if FanControl.touched { FanControl.resetAll() }
let helper = Helper()
let listener = NSXPCListener(machServiceName: "com.nav.deck.helper")
// Each connection is checked against the containing app's own signature in shouldAcceptNewConnection.
listener.delegate = helper
listener.resume()
RunLoop.main.run()
