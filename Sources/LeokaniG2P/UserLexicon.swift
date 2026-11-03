// SPDX-License-Identifier: MIT
// Leokani G2P by Milliwatt Labs (milliwattlabs.com)
//
// Custom pronunciations: brands, people, places. Checked before the lexicon and before any normaliser rule.
// The format and the rules are shared by every port (product/data/leokani-g2p-user-lexicon.schema.json):
//   - a value is phonemes (/like this/ in files, or {"phonemes": ...}) or a respelling read as written text
//     (plain text, or {"say": ...})
//   - a key with no capital letter matches any casing; a key with a capital matches only that casing, and wins
//   - "Leokani's" falls back to "Leokani": phonemes + ᵻz / s / z, or the respelling + 's
import Foundation

public enum Pronunciation: Equatable, Sendable {
    /// Kokoro-style phonemes, used as the word's base (the clause context still places stress and links)
    case phonemes(String)
    /// text read in place of the word ("shivawn" for Siobhan)
    case say(String)
}

public struct UserLexiconError: Error, LocalizedError, Equatable {
    public let message: String
    public var errorDescription: String? { message }
}

public final class UserLexicon: @unchecked Sendable {
    public static let format = "leokani-g2p-user/1"
    private var exact: [String: Pronunciation] = [:]
    private var lowerKeys: [String: Pronunciation] = [:]
    private let lock = NSLock()
    /// allowed phoneme symbols (nil: no check)
    let symbols: Set<Unicode.Scalar>?

    public init(symbols: Set<Unicode.Scalar>? = nil) { self.symbols = symbols }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return exact.count + lowerKeys.count }

    /// "/lˌAOkˈɑni/" -> phonemes; anything else -> a respelling
    public static func parse(_ value: String) throws -> Pronunciation {
        let v = value.pyStrip
        if v.pyLen >= 2, v.first1 == "/", v.last1 == "/" { return try make(.phonemes(v.sl(1, -1))) }
        return try make(.say(v))
    }

    private static func make(_ p: Pronunciation) throws -> Pronunciation {
        switch p {
        case .phonemes(let s):
            let v = s.words.joined(separator: " ")
            if v.isEmpty { throw UserLexiconError(message: "an empty pronunciation") }
            return .phonemes(v)
        case .say(let s):
            let v = s.words.joined(separator: " ")
            if v.isEmpty { throw UserLexiconError(message: "an empty pronunciation") }
            return .say(v)
        }
    }

    /// add("Leokani", .phonemes("lˌAOkˈɑni")), add("Siobhan", .say("shivawn"))
    public func add(_ word: String, _ value: Pronunciation) throws {
        let val = try UserLexicon.make(value)
        var key = word.pyStrip.rep("’", "'")
        let core = Normalizer.split(key).1
        if !core.isEmpty { key = core }                              // matched against a token's core: "Mx." -> "Mx"
        if key.isEmpty || key.unicodeScalars.contains(where: { $0.pyIsSpace }) {
            throw UserLexiconError(message: "a key is one token with no spaces: \(word)")
        }
        if case .phonemes(let ph) = val, let symbols {
            let bad = Set(ph.unicodeScalars.filter { $0 != " " && !symbols.contains($0) }).map { String($0) }.sorted()
            if !bad.isEmpty { throw UserLexiconError(message: "\(word): unknown phoneme symbols \(bad.joined(separator: " "))") }
        }
        lock.lock(); defer { lock.unlock() }
        if key != key.lower || !key.unicodeScalars.elementsEqual(key.lower.unicodeScalars) { exact[key] = val } else { lowerKeys[key] = val }
    }

    /// add("Leokani", "/lˌAOkˈɑni/") or add("Siobhan", "shivawn")
    public func add(_ word: String, _ value: String) throws { try add(word, try UserLexicon.parse(value)) }

    public func add(_ word: String, phonemes: String) throws { try add(word, .phonemes(phonemes)) }
    public func add(_ word: String, say: String) throws { try add(word, .say(say)) }

    /// every entry, exact-case keys first
    public func entries() -> [(String, Pronunciation)] {
        lock.lock(); defer { lock.unlock() }
        return exact.sorted { $0.key < $1.key }.map { ($0.key, $0.value) } + lowerKeys.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    public func removeAll() { lock.lock(); exact = [:]; lowerKeys = [:]; lock.unlock() }

    /// Add the entries of a JSON document: {"format": "leokani-g2p-user/1", "words": {...}} or a bare {word: value}.
    public func load(json data: Data) throws {
        let obj: Any
        do { obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) } catch {
            throw UserLexiconError(message: "not JSON: \(error.localizedDescription)")
        }
        guard var dict = obj as? [String: Any] else { throw UserLexiconError(message: "a user lexicon is an object: word -> pronunciation") }
        if dict["words"] != nil, let f = dict["format"] {
            guard let fs = f as? String, fs == UserLexicon.format else { throw UserLexiconError(message: "not a \(UserLexicon.format) file: \(f)") }
            guard let w = dict["words"] as? [String: Any] else { throw UserLexiconError(message: "a user lexicon is an object: word -> pronunciation") }
            dict = w
        }
        // the document's order, a later duplicate key replacing an earlier one, as the other ports' JSON readers do
        let top = obj as? [String: Any]
        let members = UserLexicon.orderedMembers(data, words: top?["words"] != nil && top?["format"] != nil)
            ?? dict.keys.sorted().map { ($0, dict[$0]!) }
        for (k, v) in members {
            if let s = v as? String {
                try add(k, s)
            } else if let o = v as? [String: Any], o.count == 1, let p = o["phonemes"] as? String {
                try add(k, .phonemes(p))
            } else if let o = v as? [String: Any], o.count == 1, let s = o["say"] as? String {
                try add(k, .say(s))
            } else {
                throw UserLexiconError(message: "an entry is {\"phonemes\": ...} or {\"say\": ...}: \(k)")
            }
        }
    }

    /// Add the entries of a TSV document: key TAB value per line, # comments, blank lines skipped.
    public func load(tsv text: String, name: String = "tsv") throws {
        for (n, raw) in text.components(separatedBy: CharacterSet.newlines).enumerated() {
            let ln = raw.pyStrip.lstrip("\u{FEFF}")
            if ln.isEmpty || ln.starts("#") { continue }
            let parts = ln.split1("\t")
            guard parts.count == 2 else { throw UserLexiconError(message: "\(name):\(n + 1): expected key<TAB>value") }
            do { try add(parts[0], parts[1]) } catch let e as UserLexiconError {
                throw UserLexiconError(message: "\(name):\(n + 1): \(e.message)")
            }
        }
    }

    /// Add the entries of a .json or .tsv file.
    public func load(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        if url.pathExtension.lowercased() == "json" { try load(json: data) } else {
            guard let s = String(data: data, encoding: .utf8) else { throw UserLexiconError(message: "\(url.lastPathComponent): not UTF-8") }
            try load(tsv: s, name: url.lastPathComponent)
        }
    }

    func get(_ core: String) -> Pronunciation? {
        let c = core.rep("’", "'")
        lock.lock(); defer { lock.unlock() }
        return exact[c] ?? lowerKeys[c.lower]
    }

    /// A token's core -> its pronunciation, possessives included, or nil.
    func rewrite(_ core: String) -> Pronunciation? {
        if let hit = get(core) { return hit }
        let c = core.rep("’", "'")
        if c.pyLen > 2, ["'s", "'S"].contains(c.sl(-2)) {
            guard let hit = get(c.sl(nil, -2)) else { return nil }
            switch hit {
            case .say(let v): return .say(v + "'s")
            case .phonemes(let v):
                let last = bareStress(v).rstripSpace().last1
                return .phonemes(v + (last.isIn("szʃʒʧʤ") ? "ᵻz" : last.isIn("ptkfθ") ? "s" : "z"))
            }
        }
        if c.pyLen > 2, c.last1 == "'", (try? c.at(-2))?.isIn("sS") == true { return get(c.sl(nil, -1)) }
        return nil
    }

    /// The members of the "words" object (or of the top level) in the order written, each value parsed on its
    /// own (JSONSerialization keeps neither the order nor the last of two duplicate keys). nil if it can't tell.
    static func orderedMembers(_ data: Data, words: Bool) -> [(String, Any)]? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let u = Array(text.utf8)
        var i = 0
        func ws() { while i < u.count, [0x20, 0x09, 0x0A, 0x0D].contains(u[i]) { i += 1 } }
        func str() -> String? {
            guard i < u.count, u[i] == 0x22 else { return nil }
            let a = i
            i += 1
            while i < u.count, u[i] != 0x22 { if u[i] == 0x5C { i += 1 }; i += 1 }
            i += 1
            guard i <= u.count else { return nil }
            return (try? JSONSerialization.jsonObject(with: Data(u[a..<i]), options: [.fragmentsAllowed])) as? String
        }
        func value() -> Range<Int>? {
            ws()
            let a = i
            guard i < u.count else { return nil }
            if u[i] == 0x22 { return str() == nil ? nil : a..<i }
            if u[i] == 0x7B || u[i] == 0x5B {
                var depth = 0
                while i < u.count {
                    if u[i] == 0x22 { if str() == nil { return nil }; continue }
                    if u[i] == 0x7B || u[i] == 0x5B { depth += 1 }
                    if u[i] == 0x7D || u[i] == 0x5D { depth -= 1; if depth == 0 { i += 1; return a..<i } }
                    i += 1
                }
                return nil
            }
            while i < u.count, ![0x2C, 0x7D, 0x5D].contains(u[i]) { i += 1 }
            return a..<i
        }
        func object() -> [(String, Range<Int>)]? {
            ws()
            guard i < u.count, u[i] == 0x7B else { return nil }
            i += 1
            var out: [(String, Range<Int>)] = []
            ws()
            if i < u.count, u[i] == 0x7D { i += 1; return out }
            while true {
                ws()
                guard let k = str() else { return nil }
                ws()
                guard i < u.count, u[i] == 0x3A else { return nil }
                i += 1
                guard let r = value() else { return nil }
                out.append((k, r))
                ws()
                if i < u.count, u[i] == 0x2C { i += 1; continue }
                if i < u.count, u[i] == 0x7D { i += 1; return out }
                return nil
            }
        }
        guard let top = object() else { return nil }
        var members = top
        if words {
            guard let w = top.last(where: { $0.0 == "words" }) else { return nil }
            i = w.1.lowerBound
            guard let inner = object() else { return nil }
            members = inner
        }
        var out: [(String, Any)] = []
        for (k, r) in members {
            guard let v = try? JSONSerialization.jsonObject(with: Data(u[r]), options: [.fragmentsAllowed]) else { return nil }
            out.append((k, v))
        }
        return out
    }
}
