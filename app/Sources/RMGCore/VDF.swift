import Foundation

/// Valve KeyValues ("VDF"/"ACF") text format: ordered, case-insensitive keys,
/// quoted strings with backslash escapes, `//` comments, optional `[$COND]` tags.
public indirect enum VDF: Equatable {
    case string(String)
    case object([(key: String, value: VDF)])

    public static func == (a: VDF, b: VDF) -> Bool {
        switch (a, b) {
        case let (.string(x), .string(y)): return x == y
        case let (.object(x), .object(y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: return false
        }
    }

    // MARK: access

    public var string: String? { if case let .string(s) = self { return s }; return nil }
    public var entries: [(key: String, value: VDF)] { if case let .object(e) = self { return e }; return [] }

    public subscript(key: String) -> VDF? {
        entries.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    /// Follows a key path, e.g. `root[path: "Software", "Valve", "Steam"]`.
    public subscript(path keys: String...) -> VDF? { lookup(keys[...]) }

    private func lookup(_ keys: ArraySlice<String>) -> VDF? {
        guard let first = keys.first else { return self }
        return self[first]?.lookup(keys.dropFirst())
    }

    /// Sets a value at a key path, creating intermediate objects. Existing key
    /// spelling (case) is preserved.
    public mutating func set(_ keys: [String], _ value: VDF) {
        guard let first = keys.first else { self = value; return }
        var e = entries
        if case .string = self { e = [] }
        if let i = e.firstIndex(where: { $0.key.caseInsensitiveCompare(first) == .orderedSame }) {
            var child = e[i].value
            child.set(Array(keys.dropFirst()), value)
            e[i].value = child
        } else {
            var child = VDF.object([])
            child.set(Array(keys.dropFirst()), value)
            e.append((first, child))
        }
        self = .object(e)
    }

    // MARK: parse

    public struct ParseError: Error, CustomStringConvertible {
        public let message: String
        public var description: String { "VDF parse error: \(message)" }
    }

    public static func parse(_ text: String) throws -> VDF {
        var p = Parser(chars: Array(text.unicodeScalars))
        let e = try p.parseEntries(topLevel: true)
        return .object(e)
    }

    private struct Parser {
        let chars: [Unicode.Scalar]
        var i = 0

        mutating func skipTrivia() {
            while i < chars.count {
                let c = chars[i]
                if c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{FEFF}" { i += 1; continue }
                if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                    while i < chars.count, chars[i] != "\n" { i += 1 }
                    continue
                }
                if c == "[" { // conditional like [$WIN32]: ignored
                    while i < chars.count, chars[i] != "]" { i += 1 }
                    i += 1; continue
                }
                break
            }
        }

        mutating func token() throws -> String? {
            skipTrivia()
            guard i < chars.count else { return nil }
            var out = String.UnicodeScalarView()
            if chars[i] == "\"" {
                i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count {
                        i += 1
                        switch chars[i] {
                        case "n": out.append("\n")
                        case "t": out.append("\t")
                        default: out.append(chars[i])
                        }
                    } else { out.append(chars[i]) }
                    i += 1
                }
                guard i < chars.count else { throw ParseError(message: "unterminated string") }
                i += 1
            } else {
                while i < chars.count, !" \t\r\n{}\"".unicodeScalars.contains(chars[i]) { out.append(chars[i]); i += 1 }
            }
            return String(out)
        }

        mutating func parseEntries(topLevel: Bool) throws -> [(key: String, value: VDF)] {
            var entries: [(key: String, value: VDF)] = []
            while true {
                skipTrivia()
                guard i < chars.count else {
                    if topLevel { return entries }
                    throw ParseError(message: "missing }")
                }
                if chars[i] == "}" {
                    if topLevel { throw ParseError(message: "unexpected }") }
                    i += 1; return entries
                }
                guard let key = try token() else { throw ParseError(message: "expected key") }
                skipTrivia()
                guard i < chars.count else { throw ParseError(message: "missing value for \(key)") }
                if chars[i] == "{" {
                    i += 1
                    entries.append((key, .object(try parseEntries(topLevel: false))))
                } else {
                    guard let v = try token() else { throw ParseError(message: "missing value for \(key)") }
                    entries.append((key, .string(v)))
                }
            }
        }
    }

    // MARK: serialize (Steam's own tab-indented style)

    public func serialized() -> String {
        var out = ""
        for (k, v) in entries { Self.write(k, v, depth: 0, into: &out) }
        return out
    }

    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func write(_ key: String, _ value: VDF, depth: Int, into out: inout String) {
        let indent = String(repeating: "\t", count: depth)
        switch value {
        case let .string(s):
            out += "\(indent)\(quote(key))\t\t\(quote(s))\n"
        case let .object(e):
            out += "\(indent)\(quote(key))\n\(indent){\n"
            for (k, v) in e { write(k, v, depth: depth + 1, into: &out) }
            out += "\(indent)}\n"
        }
    }
}
