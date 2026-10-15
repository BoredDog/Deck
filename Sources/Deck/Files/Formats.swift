import Foundation
import Yams

/// XML ↔ JSON with a simple, predictable mapping: attributes become "@name", mixed text becomes "#text",
/// repeated children become a list.
enum XMLJSON {
    private final class Node {
        let name: String, attrs: [String: String]
        var children: [Node] = [], text = ""
        init(_ name: String, _ attrs: [String: String]) { self.name = name; self.attrs = attrs }
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var stack: [Node] = [], root: Node?
        func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            let n = Node(name, attributes)
            stack.last?.children.append(n)
            if root == nil { root = n }
            stack.append(n)
        }
        func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { stack.removeLast() }
        func parser(_ p: XMLParser, foundCharacters s: String) { stack.last?.text += s }
        func parser(_ p: XMLParser, foundCDATA d: Data) { stack.last?.text += String(decoding: d, as: UTF8.self) }
    }

    static func parse(_ data: Data) throws -> [String: Any] {
        let b = Builder()
        let p = XMLParser(data: data)
        p.delegate = b
        p.shouldResolveExternalEntities = false
        guard p.parse(), let root = b.root else { throw Engine.Failed(tool: "xml", detail: p.parserError?.localizedDescription ?? "empty") }
        return [root.name: value(root)]
    }

    private static func value(_ n: Node) -> Any {
        let text = n.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.attrs.isEmpty && n.children.isEmpty { return text }
        var d: [String: Any] = [:]
        for (k, v) in n.attrs { d["@" + k] = v }
        let counts = Dictionary(n.children.map { ($0.name, 1) }, uniquingKeysWith: +)
        for c in n.children {
            d[c.name] = counts[c.name]! > 1 ? ((d[c.name] as? [Any]) ?? []) + [value(c)] : value(c)
        }
        if !text.isEmpty { d["#text"] = text }
        return d
    }

    static func xml(_ v: Any) -> String {
        let body: String
        if let d = v as? [String: Any], d.count == 1, let (k, val) = d.first, !(val is [Any]) { body = element(k, val, 0) }
        else if v is [Any] { body = element("root", ["item": v], 0) }
        else { body = element("root", v, 0) }
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + body
    }

    // shortcut: a list inside a list is flattened into repeated elements; fine for typical data files.
    private static func element(_ key: String, _ v: Any, _ depth: Int) -> String {
        let pad = String(repeating: "  ", count: depth), name = safeName(key)
        if let list = v as? [Any] { return list.map { element(key, $0, depth) }.joined() }
        guard let d = v as? [String: Any] else {
            if v is NSNull { return "\(pad)<\(name)/>\n" }
            return "\(pad)<\(name)>\(escape(scalar(v)))</\(name)>\n"
        }
        let attrs = d.keys.filter { $0.hasPrefix("@") }.sorted().map { " \(safeName(String($0.dropFirst())))=\"\(escape(scalar(d[$0]!)))\"" }.joined()
        let kids = d.keys.filter { !$0.hasPrefix("@") && $0 != "#text" }.sorted()
        let text = d["#text"].map { escape(scalar($0)) } ?? ""
        if kids.isEmpty { return "\(pad)<\(name)\(attrs)>\(text)</\(name)>\n" }
        return "\(pad)<\(name)\(attrs)>\(text)\n" + kids.map { element($0, d[$0]!, depth + 1) }.joined() + "\(pad)</\(name)>\n"
    }

    private static func scalar(_ v: Any) -> String {
        if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
        return "\(v)"
    }

    private static func safeName(_ s: String) -> String {
        var out = String(s.map { $0.isLetter || $0.isNumber || "_-.:".contains($0) ? $0 : "_" })
        if out.isEmpty || out.first!.isNumber || "-.".contains(out.first!) { out = "_" + out }
        return out
    }

    /// Escapes text for XML and drops control characters XML can't hold.
    static func escape(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\t", "\n", "\r": out.unicodeScalars.append(u)
            default: if u.value >= 0x20 { out.unicodeScalars.append(u) }
            }
        }
        return out
    }
}

enum YAMLInput {
    static func parse(_ text: String) throws -> Any {
        func plain(_ v: Any) -> Any {
            if let d = v as? [AnyHashable: Any] { return Dictionary(d.map { ("\($0.key.base)", plain($0.value)) }, uniquingKeysWith: { a, _ in a }) }
            if let a = v as? [Any] { return a.map(plain) }
            return v
        }
        return plain(try Yams.load(yaml: text) ?? NSNull())
    }
}

/// A small TOML reader: tables, arrays of tables, dotted and quoted keys, strings (all four kinds),
/// numbers, booleans, arrays and inline tables. Dates and times come out as text.
enum TOML {
    struct Bad: LocalizedError {
        let line: Int
        var errorDescription: String? { "This TOML file has a mistake on line \(line)." }
    }

    private final class Table { var d: [String: Any] = [:] }

    static func parse(_ text: String) throws -> [String: Any] {
        var p = Parser(c: Array(text))
        return try p.document()
    }

    private struct Parser {
        let c: [Character]
        var i = 0

        func bad() -> Bad { Bad(line: c[..<min(i, c.count)].filter(\.isNewline).count + 1) }
        var at: Character? { i < c.count ? c[i] : nil }
        func peek(_ n: Int) -> Character? { i + n < c.count ? c[i + n] : nil }
        func starts(_ s: String) -> Bool { Array(s).enumerated().allSatisfy { peek($0.offset) == $0.element } }
        mutating func skipSpaces() { while at == " " || at == "\t" { i += 1 } }
        mutating func skipComment() { if at == "#" { while let ch = at, !ch.isNewline { i += 1 } } }
        mutating func skipBlank() { while true { skipSpaces(); skipComment(); if let ch = at, ch.isNewline { i += 1 } else { return } } }
        mutating func expect(_ ch: Character) throws { guard at == ch else { throw bad() }; i += 1 }

        mutating func document() throws -> [String: Any] {
            let root = Table()
            var current = root
            while true {
                skipBlank()
                guard at != nil else { break }
                if at == "[" {
                    let many = peek(1) == "["
                    i += many ? 2 : 1
                    skipSpaces()
                    let path = try key()
                    skipSpaces()
                    try expect("]")
                    if many { try expect("]") }
                    current = try open(root, path, appending: many)
                } else {
                    try pair(into: current)
                }
                skipSpaces(); skipComment()
                guard at == nil || at!.isNewline else { throw bad() }
            }
            return plain(root) as! [String: Any]
        }

        mutating func pair(into t: Table) throws {
            let path = try key()
            skipSpaces()
            try expect("=")
            skipSpaces()
            let v = try value()
            let parent = try open(t, Array(path.dropLast()), appending: false)
            parent.d[path.last!] = v
        }

        mutating func key() throws -> [String] {
            var parts: [String] = []
            while true {
                skipSpaces()
                if at == "\"" || at == "'" { parts.append(try string()) }
                else {
                    let start = i
                    while let ch = at, ch.isLetter || ch.isNumber || ch == "_" || ch == "-" { i += 1 }
                    guard i > start else { throw bad() }
                    parts.append(String(c[start..<i]))
                }
                skipSpaces()
                guard at == "." else { return parts }
                i += 1
            }
        }

        /// Walks to (creating as needed) the table at `path`. `appending` adds a new entry to an array of tables.
        func open(_ root: Table, _ path: [String], appending: Bool) throws -> Table {
            var t = root
            for (n, k) in path.enumerated() {
                let last = n == path.count - 1
                if last && appending {
                    let new = Table()
                    switch t.d[k] {
                    case nil: t.d[k] = [new]
                    case let list as [Table]: t.d[k] = list + [new]
                    default: throw bad()
                    }
                    return new
                }
                switch t.d[k] {
                case nil: let new = Table(); t.d[k] = new; t = new
                case let sub as Table: t = sub
                case let list as [Table] where !list.isEmpty: t = list.last!
                default: throw bad()
                }
            }
            return t
        }

        mutating func value() throws -> Any {
            switch at {
            case "\"", "'": return try string()
            case "[":
                i += 1
                var list: [Any] = []
                while true {
                    skipBlank()
                    if at == "]" { i += 1; return list }
                    list.append(try value())
                    skipBlank()
                    if at == "," { i += 1 } else { try expect("]"); return list }
                }
            case "{":
                i += 1
                let t = Table()
                skipSpaces()
                if at == "}" { i += 1; return t }
                while true {
                    try pair(into: t)
                    skipSpaces()
                    if at == "," { i += 1 } else { try expect("}"); return t }
                }
            default:
                let start = i
                while let ch = at, !ch.isNewline, !",]}#".contains(ch) {
                    // "1979-05-27 07:32:00": a date and a time separated by one space.
                    if ch == " ", i - start == 10, peek(1)?.isNumber == true { i += 1; continue }
                    if ch == " " || ch == "\t" { break }
                    i += 1
                }
                let raw = String(c[start..<i])
                if raw == "true" { return true }
                if raw == "false" { return false }
                let s = raw.replacingOccurrences(of: "_", with: "")
                for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where s.hasPrefix(prefix) {
                    if let n = Int(s.dropFirst(2), radix: radix) { return n }
                }
                if let n = Int(s) { return n }
                if let d = Double(s), d.isFinite, s.first?.isLetter == false { return d }
                if ["inf", "+inf", "-inf", "nan", "+nan", "-nan"].contains(s) { return s }
                if raw.first?.isNumber == true, raw.contains("-") || raw.contains(":") { return raw }
                throw bad()
            }
        }

        mutating func string() throws -> String {
            let literal = at == "'"
            let q: Character = literal ? "'" : "\""
            let multi = starts(String(repeating: q, count: 3))
            i += multi ? 3 : 1
            if multi, let ch = at, ch.isNewline { i += 1 }
            var out = ""
            while true {
                guard let ch = at else { throw bad() }
                if ch == q {
                    if !multi { i += 1; return out }
                    if starts(String(repeating: q, count: 3)) {
                        // Up to two quotes may sit right before the closing three.
                        var extra = 0
                        while peek(3 + extra) == q, extra < 2 { extra += 1 }
                        out += String(repeating: q, count: extra)
                        i += 3 + extra
                        return out
                    }
                }
                if ch.isNewline && !multi { throw bad() }
                if ch == "\\" && !literal {
                    i += 1
                    guard let e = at else { throw bad() }
                    switch e {
                    case "n": out += "\n"
                    case "t": out += "\t"
                    case "r": out += "\r"
                    case "b": out += "\u{8}"
                    case "f": out += "\u{c}"
                    case "e": out += "\u{1b}"
                    case "\"": out += "\""
                    case "\\": out += "\\"
                    case "u", "U":
                        let n = e == "u" ? 4 : 8
                        guard i + n < c.count, let code = UInt32(String(c[(i + 1)...(i + n)]), radix: 16), let u = Unicode.Scalar(code) else { throw bad() }
                        out.unicodeScalars.append(u)
                        i += n
                    case let w where w.isWhitespace && multi:
                        // Line-ending backslash: skip the break and the next line's leading space.
                        while let s = at, s.isWhitespace { i += 1 }
                        continue
                    default: throw bad()
                    }
                    i += 1
                    continue
                }
                out.append(ch)
                i += 1
            }
        }

        func plain(_ v: Any) -> Any {
            if let t = v as? Table { return t.d.mapValues(plain) }
            if let list = v as? [Table] { return list.map(plain) }
            if let list = v as? [Any] { return list.map(plain) }
            return v
        }
    }
}
