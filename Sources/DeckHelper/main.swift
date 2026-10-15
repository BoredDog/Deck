import Foundation

// DeckHelper: a root launchd daemon (installed once with SMAppService) that blocks websites during focus.
// It can do exactly two things: write Deck's marked block into /etc/hosts, and remove it. Nothing else.

@objc(DeckHelperProtocol) protocol DeckHelperProtocol {
    func block(_ domains: [String], reply: @escaping (Bool) -> Void)
    func unblock(reply: @escaping (Bool) -> Void)
}

final class Helper: NSObject, DeckHelperProtocol, NSXPCListenerDelegate {
    private let hosts = URL(fileURLWithPath: "/etc/hosts")
    private let lock = NSLock()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        let iface = NSXPCInterface(with: DeckHelperProtocol.self)
        iface.setClasses(NSSet(objects: NSArray.self, NSString.self) as! Set<AnyHashable>, for: #selector(DeckHelperProtocol.block(_:reply:)), argumentIndex: 0, ofReply: false)
        c.exportedInterface = iface
        c.exportedObject = self
        c.resume()
        return true
    }

    func block(_ domains: [String], reply: @escaping (Bool) -> Void) {
        reply(edit { HostsFile.addingBlock($0, domains: domains) })
    }

    func unblock(reply: @escaping (Bool) -> Void) {
        reply(edit { HostsFile.removingBlock($0) })
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

let helper = Helper()
let listener = NSXPCListener(machServiceName: "com.nav.deck.helper")
// shortcut: an ad-hoc signed app can only be pinned by identifier, which any local program could copy; with a
// Developer ID, add `anchor apple generic and certificate leaf[subject.OU] = "<TEAMID>"` to this requirement.
listener.setConnectionCodeSigningRequirement("identifier \"com.nav.deck\"")
listener.delegate = helper
listener.resume()
RunLoop.main.run()
