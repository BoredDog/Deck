import Foundation
import SwiftData
import UniformTypeIdentifiers
import CoreServices

/// Sorts a folder into subfolders: suggest first (`plan`), then move (`apply`) with a full `undo`.
/// Everything stays inside the chosen folder and nothing is ever overwritten.
enum Organizer {

    // MARK: plan

    static func plan(folder: URL, options: OrganizeOptions, rules: [OrganizeRule], courses: [String]) async -> [PlannedMove] {
        let matchers = courses.map(CourseMatcher.init)
        let reserved = reservedNames(rules: rules, matchers: matchers)
        let files = scan(folder, deep: options.includeSubfolders) { reserved.contains($0.lowercased()) || isYear($0) }
        let groups = [options.primary] + (options.secondary.map { $0 == options.primary ? [] : [$0] } ?? [])
        let now = Date()
        var taken = Set<String>()
        var out: [PlannedMove] = []
        for f in files {
            var parts: [String] = [], reasons: [String] = []
            if let r = rules.first(where: { matches($0, f, now: now) }) {
                parts = safeComponents(r.folder)
                reasons = ["Your rule: \(describe(r))"]
            } else {
                for g in groups {
                    guard let (p, why) = component(g, f, matchers) else { continue }
                    parts += p
                    reasons.append(why)
                }
            }
            let oldName = f.url.lastPathComponent
            var name = oldName
            if options.cleanNames {
                name = cleanName(oldName)
                if name != oldName { reasons.append("clearer name") }
            }
            let here = f.url.deletingLastPathComponent()
            let dir = parts.reduce(folder) { $0.appendingPathComponent($1, isDirectory: true) }
            let target = parts.isEmpty ? here : dir
            if name == oldName, parts.isEmpty || target.resolvingSymlinksInPath().path == here.resolvingSymlinksInPath().path { continue }
            let dest = free(in: target, name: name, source: f.url, taken: &taken)
            var reason = reasons.joined(separator: " · ")
            if let first = reason.first { reason = first.uppercased() + reason.dropFirst() }
            out.append(PlannedMove(source: f.url, destination: dest, reason: reason))
        }
        return out
    }

    /// Distinct course codes (or names) from deadlines and the timetable.
    static func knownCourses() async -> [String] {
        await MainActor.run {
            let d = ((try? Store.context.fetch(FetchDescriptor<Deadline>())) ?? []).map(\.course)
            let c = ((try? Store.context.fetch(FetchDescriptor<ClassSlot>())) ?? []).map(\.course)
            return Set((d + c).map { $0.trimmingCharacters(in: .whitespaces) }).filter { !$0.isEmpty }.sorted()
        }
    }

    // MARK: grouping

    static let typeFolders = ["Images", "Screenshots", "Videos", "Audio", "Documents", "PDFs", "Slides", "Spreadsheets",
                              "Code", "Archives", "Installers", "Fonts", "Other"]
    private static let slideExts: Set<String> = ["ppt", "pptx", "key", "odp"]
    private static let sheetExts: Set<String> = ["xls", "xlsx", "numbers", "csv", "tsv", "ods"]
    private static let fontExts: Set<String> = ["ttf", "otf", "ttc", "woff", "woff2", "dfont"]
    private static let codeExts: Set<String> = ["swift", "py", "ipynb", "js", "jsx", "ts", "tsx", "c", "h", "cc", "cpp", "hpp",
        "m", "mm", "java", "kt", "rb", "go", "rs", "php", "html", "css", "scss", "json", "yaml", "yml", "xml", "sh", "zsh",
        "sql", "r", "lua", "dart", "cs", "scala", "hs", "ml", "asm", "v", "vhd", "vhdl", "toml"]

    /// Which type folder a file belongs in (Tidy's kinds, split finer).
    static func kind(of url: URL) -> String {
        let e = url.pathExtension.lowercased(), name = url.lastPathComponent
        if e == "pdf" { return "PDFs" }
        if slideExts.contains(e) { return "Slides" }
        if sheetExts.contains(e) { return "Spreadsheets" }
        if fontExts.contains(e) { return "Fonts" }
        if codeExts.contains(e) || UTType(filenameExtension: e)?.conforms(to: .sourceCode) == true { return "Code" }
        let k = Tidy.folder(for: e)
        if k == "Images", name.hasPrefix("Screenshot ") || name.hasPrefix("Screen Shot ") { return "Screenshots" }
        return k
    }

    private static let monthNames = { () -> [String] in
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); return f.standaloneMonthSymbols
    }()

    /// Folder parts and a plain reason for one grouping, or nil when it doesn't apply (no course found, rules-only).
    private static func component(_ g: GroupBy, _ f: Item, _ matchers: [CourseMatcher]) -> ([String], String)? {
        switch g {
        case .type:
            let k = kind(of: f.url)
            return ([k], k)
        case .date:
            let c = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: f.created ?? f.modified ?? Date())
            let y = c.year ?? 2000, m = c.month ?? 1, month = monthNames[m - 1]
            return (["\(y)", String(format: "%02d %@", m, month)], "\(month) \(y)")
        case .course:
            let name = f.url.deletingPathExtension().lastPathComponent
            var m = matchers.first { $0.matches(name) }
            if m == nil, !matchers.isEmpty {
                let sites = f.sites
                m = matchers.first { m in sites.contains { m.matches($0) } }
            }
            guard let m else { return nil }
            return ([m.folder], m.folder)
        case .rules:
            return nil   // rules are checked before any grouping
        }
    }

    /// Top-level folder names this plan could create; files already inside them are left alone.
    private static func reservedNames(rules: [OrganizeRule], matchers: [CourseMatcher]) -> Set<String> {
        Set((typeFolders + matchers.map(\.folder) + rules.compactMap { safeComponents($0.folder).first }).map { $0.lowercased() })
    }

    private static func isYear(_ s: String) -> Bool { s.count == 4 && s.allSatisfy(\.isNumber) }

    /// Rule folder text as path parts that can't leave the chosen folder.
    static func safeComponents(_ path: String) -> [String] {
        path.split(separator: "/").map { $0.replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    // MARK: rules

    private static func matches(_ r: OrganizeRule, _ f: Item, now: Date) -> Bool {
        let v = r.value.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, !safeComponents(r.folder).isEmpty else { return false }
        switch r.field {
        case .nameContains: return f.url.lastPathComponent.localizedCaseInsensitiveContains(v)
        case .extensionIs:
            let exts = v.lowercased().split(whereSeparator: { $0 == "," || $0 == " " }).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            return exts.contains(f.url.pathExtension.lowercased())
        case .fromSiteContains: return f.sites.contains { $0.localizedCaseInsensitiveContains(v) }
        case .olderThanDays:
            guard let d = Double(v), let date = f.created ?? f.modified else { return false }
            return now.timeIntervalSince(date) > d * 86_400
        case .largerThanMB:
            guard let mb = Double(v) else { return false }
            return Double(f.size) > mb * 1_000_000
        }
    }

    private static func describe(_ r: OrganizeRule) -> String {
        let v = r.value.trimmingCharacters(in: .whitespaces)
        switch r.field {
        case .nameContains: return "name has “\(v)”"
        case .extensionIs: return "\(v) file"
        case .fromSiteContains: return "downloaded from \(v)"
        case .olderThanDays: return "older than \(v) days"
        case .largerThanMB: return "bigger than \(v) MB"
        }
    }

    // MARK: courses

    /// Matches one course (its code and the name the user gave it) against a file name or download link.
    struct CourseMatcher {
        let folder: String
        private var codes: [NSRegularExpression] = []
        private var wordSets: [[String]] = []
        private static let stop: Set<String> = ["and", "of", "the", "to", "in", "for", "a", "an", "with", "on"]

        init(_ course: String) {
            let name = CourseNames.name(course)
            folder = safeComponents(name.replacingOccurrences(of: "/", with: "-")).first ?? course
            for n in Set([course, name]) {
                let parts = n.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                guard !parts.isEmpty else { continue }
                if n.contains(where: \.isNumber) {
                    // Codes: "M26EC2.102" also matches "EC2.102" / "ec2_102" (the term prefix is dropped).
                    var variants = [parts]
                    if let r = parts[0].range(of: #"^[a-z]\d+(?=[a-z])"#, options: .regularExpression) {
                        let rest = [String(parts[0][r.upperBound...])] + parts.dropFirst()
                        if rest.joined().count >= 4 { variants.append(rest) }
                    }
                    codes += variants.compactMap { v in
                        try? NSRegularExpression(pattern: "(?<![a-z0-9])" + v.map(NSRegularExpression.escapedPattern).joined(separator: "[^a-z0-9]*") + "(?![a-z0-9])")
                    }
                } else {
                    let words = parts.filter { !Self.stop.contains($0) }
                    if !words.isEmpty { wordSets.append(words) }
                }
            }
        }

        func matches(_ text: String) -> Bool {
            let text = text.removingPercentEncoding ?? text
            let lower = text.lowercased(), range = NSRange(lower.startIndex..., in: lower)
            if codes.contains(where: { $0.firstMatch(in: lower, range: range) != nil }) { return true }
            let tokens = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            for words in wordSets {
                let initials = String(words.map { $0.first! }).uppercased()
                for i in tokens.indices {
                    if words.count >= 2, tokens[i] == initials { return true }   // "LA" for Linear Algebra (capitals only)
                    for n in 1...min(words.count, tokens.count - i) {
                        let s = tokens[i..<i + n].joined().lowercased()
                        if Self.abbreviates(Substring(s), words[...], minPrefix: words.count == 1 ? 4 : 3) { return true }
                    }
                }
            }
            return false
        }

        /// "linalg" ~ [linear, algebra]: the text is a run of word prefixes, every word used, in order.
        static func abbreviates(_ s: Substring, _ words: ArraySlice<String>, minPrefix: Int) -> Bool {
            guard let w = words.first else { return s.isEmpty }
            let low = min(minPrefix, w.count)
            guard s.count >= low else { return false }
            for k in stride(from: min(w.count, s.count), through: low, by: -1) where s.hasPrefix(w.prefix(k)) {
                if abbreviates(s.dropFirst(k), words.dropFirst(), minPrefix: minPrefix) { return true }
            }
            return false
        }
    }

    /// Download links macOS saved for a file ("Where from" in Get Info).
    static func whereFroms(_ url: URL) -> [String] {
        let key = "com.apple.metadata:kMDItemWhereFroms"
        let len = getxattr(url.path, key, nil, 0, 0, 0)
        guard len > 0 else { return [] }
        var data = Data(count: len)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, key, $0.baseAddress, len, 0, 0) }
        guard read == len else { return [] }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String] ?? []
    }

    // MARK: scanning

    struct Item {
        let url: URL
        let size: Int64
        let created: Date?, modified: Date?, accessed: Date?
        var sites: [String] { Organizer.whereFroms(url) }
    }

    private static let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isAliasFileKey,
                                                 .fileSizeKey, .creationDateKey, .contentModificationDateKey, .contentAccessDateKey]

    /// Same list as `Tidy.unfinished` (which is main-actor bound).
    private static let unfinished: Set<String> = ["download", "crdownload", "part", "partial", "aria2", "tmp"]

    /// Plain files only: no hidden files, packages, links/aliases or unfinished downloads. `skipFolder` gets top-level folder names.
    static func scan(_ folder: URL, deep: Bool, skipFolder: (String) -> Bool = { _ in false }) -> [Item] {
        let opts: FileManager.DirectoryEnumerationOptions = deep ? [.skipsHiddenFiles, .skipsPackageDescendants]
                                                                 : [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: opts) else { return [] }
        var out: [Item] = []
        while let url = e.nextObject() as? URL {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true {
                if v.isPackage == true || (e.level == 1 && skipFolder(url.lastPathComponent)) { e.skipDescendants() }
                continue
            }
            guard v.isRegularFile == true, v.isSymbolicLink != true, v.isAliasFile != true,
                  !unfinished.contains(url.pathExtension.lowercased()) else { continue }
            out.append(Item(url: url, size: Int64(v.fileSize ?? 0), created: v.creationDate, modified: v.contentModificationDate,
                            accessed: v.contentAccessDate))
        }
        return out.sorted { $0.url.path < $1.url.path }
    }

    /// Same naming as `FileManager.freeURL` ("name 2.ext"), but also avoids names already given out in this plan.
    private static func free(in dir: URL, name: String, source: URL, taken: inout Set<String>) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var n = 1
        while true {
            let file = n == 1 ? name : (ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            let url = dir.appendingPathComponent(file), key = url.standardizedFileURL.path.lowercased()
            let isSelf = key == source.standardizedFileURL.path.lowercased()
            if !taken.contains(key), isSelf || !FileManager.default.fileExists(atPath: url.path) {
                taken.insert(key)
                return url
            }
            n += 1
        }
    }

    // MARK: clean names

    private static let numbering: Set<String> = ["lecture", "lec", "hw", "homework", "week", "wk", "chapter", "ch", "part", "pt",
        "unit", "lab", "assignment", "quiz", "q", "ex", "exercise", "tut", "tutorial", "sheet", "set", "module", "mod",
        "session", "day", "problem", "test", "exam", "midterm", "v", "version", "page", "slide", "slides", "sec", "section",
        "class", "task", "project", "phase", "round", "level", "step", "worksheet", "paper", "vol", "volume", "episode", "ep"]

    /// "Report (1).PDF" → "Report.pdf", "IMG_20261016_103245.JPG" → "Photo 2026-10-16 10.32.45.jpg". Never empty.
    static func cleanName(_ name: String) -> String {
        var base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        if base.isEmpty || ext.contains(" ") || ext.count > 8 { base = name; ext = "" }
        var b = base

        // Copy markers, repeatedly: " (1)", " copy", " copy 2", " - Copy", "-1" / "_1" (but not "Lecture_1").
        while true {
            let before = b
            for p in [#"\s*\(\d+\)$"#, #"(?i)(\s+-)?\s+copy(\s+\(?\d+\)?)?$"#] {
                if let r = b.range(of: p, options: .regularExpression), r.lowerBound > b.startIndex { b.removeSubrange(r) }
            }
            if let r = b.range(of: #"[A-Za-z]+[-_]1$"#, options: .regularExpression),
               !numbering.contains(String(b[r].dropLast(2)).lowercased()) {
                b.removeLast(2)
            }
            if b == before { break }
        }

        // Camera names.
        if let m = b.firstMatch(of: #/^(IMG|PXL|VID|DSC)[_-]?(\d{4})(\d{2})(\d{2})[_-](\d{2})(\d{2})(\d{2})\d*(.*)$/#) {
            let what = m.1 == "VID" ? "Video" : "Photo"
            b = "\(what) \(m.2)-\(m.3)-\(m.4) \(m.5).\(m.6).\(m.7)\(m.8)"
        } else if let m = b.firstMatch(of: #/^(IMG|VID|DSC|DSCN|DSCF)[_-]?(\d{3,})$/#) {
            b = "\(m.1 == "VID" ? "Video" : "Photo") \(m.2)"
        }

        // Spacing, then "final FINAL v2" noise → one "final".
        var words = b.replacingOccurrences(of: "_", with: " ").split(separator: " ").map(String.init)
        if let i = words.firstIndex(where: { $0.lowercased() == "final" }) {
            var kept = Array(words[...i]), afterFinal = true
            for w in words[(i + 1)...] {
                let isFinal = w.lowercased() == "final", isVersion = w.range(of: #"^[vV]\d+$"#, options: .regularExpression) != nil
                if isFinal || (isVersion && afterFinal) { afterFinal = true; continue }
                afterFinal = false
                kept.append(w)
            }
            words = kept
        }
        b = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " -."))
        if b.isEmpty { b = base }
        return ext.isEmpty ? b : "\(b).\(ext.lowercased())"
    }

    // MARK: apply / undo

    nonisolated(unsafe) static var undoFile = Vault.folder.appendingPathComponent("organize-undo.json")

    static var history: [UndoRecord] {
        get { (try? JSONDecoder().decode([UndoRecord].self, from: Data(contentsOf: undoFile))) ?? [] }
        set { try? JSONEncoder().encode(Array(newValue.suffix(10))).write(to: undoFile, options: .atomic) }
    }

    static var lastRecord: UndoRecord? { history.last }

    /// Moves the ticked files. If any move fails, everything from this batch goes back and the error is thrown.
    @MainActor static func apply(_ moves: [PlannedMove]) throws -> UndoRecord {
        let fm = FileManager.default
        var done: [UndoRecord.Pair] = [], created: [URL] = []
        do {
            for m in moves where m.include {
                let dir = m.destination.deletingLastPathComponent()
                created += try makeFolders(dir)
                var dest = m.destination
                if fm.fileExists(atPath: dest.path), !samePath(dest, m.source) {
                    dest = fm.freeURL(in: dir, name: dest.deletingPathExtension().lastPathComponent, ext: dest.pathExtension)
                }
                try move(m.source, to: dest)
                done.append(.init(from: m.source, to: dest))
            }
        } catch {
            for p in done.reversed() { try? move(p.to, to: p.from) }
            removeIfEmpty(created)
            throw error
        }
        let record = UndoRecord(date: Date(), folder: commonFolder(done), moves: done, created: created)
        if !done.isEmpty { history.append(record) }
        return record
    }

    /// Puts files back where they were (next to a same-named file if one appeared since) and removes folders left empty.
    @MainActor static func undo(_ record: UndoRecord) throws {
        let fm = FileManager.default
        var failed: [UndoRecord.Pair] = [], firstError: Error?
        for p in record.moves.reversed() where fm.fileExists(atPath: p.to.path) {
            do {
                let dir = p.from.deletingLastPathComponent()
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                var back = p.from
                if fm.fileExists(atPath: back.path), !samePath(back, p.to) {
                    back = fm.freeURL(in: dir, name: back.deletingPathExtension().lastPathComponent, ext: back.pathExtension)
                }
                try move(p.to, to: back)
            } catch {
                failed.append(p)
                firstError = firstError ?? error
            }
        }
        removeIfEmpty(record.created)
        var h = history
        if let i = h.lastIndex(where: { $0.date == record.date }) {
            if failed.isEmpty { h.remove(at: i) } else { h[i].moves = failed.reversed() }
            history = h
        }
        if let firstError { throw firstError }
    }

    private static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path.lowercased() == b.standardizedFileURL.path.lowercased()
    }

    /// moveItem refuses a rename that only changes letter case on a case-insensitive disk, so that goes via a temporary name.
    private static func move(_ from: URL, to: URL) throws {
        let fm = FileManager.default
        if from.path != to.path, samePath(from, to) {
            let tmp = from.deletingLastPathComponent().appendingPathComponent(".deck-rename-\(UUID().uuidString)")
            try fm.moveItem(at: from, to: tmp)
            do { try fm.moveItem(at: tmp, to: to) } catch { try? fm.moveItem(at: tmp, to: from); throw error }
        } else {
            try fm.moveItem(at: from, to: to)
        }
    }

    /// Creates `dir` and returns the folders that didn't exist before, deepest first.
    private static func makeFolders(_ dir: URL) throws -> [URL] {
        var missing: [URL] = [], d = dir.standardizedFileURL
        while !FileManager.default.fileExists(atPath: d.path), d.path != "/" {
            missing.append(d)
            d = d.deletingLastPathComponent()
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return missing
    }

    private static func removeIfEmpty(_ folders: [URL]) {
        for f in folders.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: f.path),
                  items.allSatisfy({ $0 == ".DS_Store" }) else { continue }
            try? FileManager.default.removeItem(at: f)
        }
    }

    private static func commonFolder(_ pairs: [UndoRecord.Pair]) -> URL {
        let all = pairs.flatMap { [$0.from, $0.to] }.map { $0.deletingLastPathComponent().standardizedFileURL.pathComponents }
        guard var common = all.first else { return URL(fileURLWithPath: "/") }
        for p in all.dropFirst() { common = zip(common, p).prefix { $0 == $1 }.map(\.0) }
        return URL(fileURLWithPath: NSString.path(withComponents: common), isDirectory: true)
    }

    // MARK: clean-up suggestions

    static let appFolders = ["/Applications", "/Applications/Utilities", NSHomeDirectory() + "/Applications"].map { URL(fileURLWithPath: $0) }

    static func cleanup(in folder: URL, includeSubfolders: Bool) async -> CleanupFindings {
        await cleanup(in: folder, includeSubfolders: includeSubfolders, appFolders: appFolders)
    }

    static func cleanup(in folder: URL, includeSubfolders: Bool, appFolders: [URL], now: Date = Date()) async -> CleanupFindings {
        let files = scan(folder, deep: includeSubfolders)
        let letters = { (s: String) in String(s.lowercased().filter { $0.isLetter && $0.isASCII }) }
        let apps = appFolders.flatMap { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? [] }
            .filter { $0.hasSuffix(".app") }.map { letters(String($0.dropLast(4))) }.filter { $0.count >= 4 }
        var found = CleanupFindings()

        // "Firefox 131.0.dmg" → "firefox"; old if an installed app's name starts it.
        found.oldInstallers = files.filter { f in
            guard ["dmg", "pkg", "mpkg"].contains(f.url.pathExtension.lowercased()) else { return false }
            let key = letters(String(f.url.deletingPathExtension().lastPathComponent.prefix { !$0.isNumber }))
            return apps.contains { key.hasPrefix($0) }
        }.map(\.url)

        let modified = Dictionary(files.map { ($0.url, $0.modified ?? .distantPast) }, uniquingKeysWith: { a, _ in a })
        found.duplicates = DuplicateFinder.groups(files.map { ($0.url, $0.size) }, hash: DuplicateFinder.sha256)
            .map { $0.sorted { modified[$0]! > modified[$1]! } }
            .sorted { $0[0].path < $1[0].path }

        found.bigForgotten = files.filter { f in
            guard f.size >= 200_000_000 else { return false }
            let used = [lastUsed(f.url), f.accessed].compactMap { $0 }.max() ?? f.modified ?? now
            return now.timeIntervalSince(used) > 180 * 86_400
        }.map(\.url)
        return found
    }

    /// When the file was last opened, as Spotlight knows it.
    private static func lastUsed(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}
