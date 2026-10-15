import Foundation

// Shared by Deck and DeckHelper: Sources/DeckHelper/HostsFile.swift is a symlink to this file. Foundation only.

/// The marked block Deck adds to /etc/hosts during focus. Everything outside the markers is left exactly as it was.
enum HostsFile {
    static let start = "# Deck focus start", end = "# Deck focus end"
    static let maxDomains = 500

    /// The helper runs as root, so it only accepts plain names like "youtube.com".
    static func isValid(_ domain: String) -> Bool {
        domain.range(of: "^[a-z0-9.-]{1,253}$", options: .regularExpression) != nil
            && domain.contains(".") && !domain.hasPrefix(".") && !domain.hasPrefix("-")
    }

    /// `hosts` without Deck's block. A start marker with no end marker loses only the marker line.
    static func removingBlock(_ hosts: String) -> String {
        var lines = hosts.components(separatedBy: "\n")
        while let s = lines.firstIndex(of: start) {
            let e = lines[s...].firstIndex(of: end) ?? s
            lines.removeSubrange(s...e)
        }
        return lines.joined(separator: "\n")
    }

    /// `hosts` with a fresh block for `domains` (and their www. names), both IPv4 and IPv6. Nil if any domain is invalid.
    static func addingBlock(_ hosts: String, domains: [String]) -> String? {
        guard !domains.isEmpty, domains.count <= maxDomains, domains.allSatisfy(isValid) else { return nil }
        var base = removingBlock(hosts)
        if !base.isEmpty && !base.hasSuffix("\n") { base += "\n" }
        let names = domains.flatMap { $0.hasPrefix("www.") ? [$0] : [$0, "www.\($0)"] }
        let lines = names.flatMap { ["0.0.0.0 \($0)", ":: \($0)"] }
        return base + ([start] + lines + [end]).joined(separator: "\n") + "\n"
    }
}
