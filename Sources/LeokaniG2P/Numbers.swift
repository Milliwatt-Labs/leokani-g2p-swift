// SPDX-License-Identifier: MIT
// Leokani G2P by Milliwatt Labs (milliwattlabs.com)
import Foundation

let PRIMARY = "ˈ", SECONDARY = "ˌ"
let PH = "\u{E000}"            // "word" + PH + phonemes: a word whose base is given

func bareStress(_ s: String) -> String { s.rep(PRIMARY, "").rep(SECONDARY, "") }

/// Digits read the way the reference reads them; atoms come from the lexicon file. say() returns nil for a token it
/// has no rule for.
final class Numbers {
    let a: [String: String]
    let word: (String) -> String?
    static let ORD: Set<String> = ["st", "nd", "rd", "th"]
    static let SUFFIX_SOUND = ["st": "st", "nd": "ənd", "rd": "d", "th": "θ"]

    init(_ atoms: [String: String], word: @escaping (String) -> String?) { a = atoms; self.word = word }

    func group(_ n: Int, pre: Bool = false) throws -> [String] {
        let h = n / 100, r = n % 100
        var out: [String] = h != 0 ? [try a.req(String(h)) + a.req("hundred")] : []
        if r != 0 {
            if pre, let p = a["pre:\(r)"] { out.append(p) } else { out.append(try a.req(String(r))) }
        }
        return out
    }

    func integer(_ digits: String) throws -> [String]? {
        var n = try pyInt(digits)
        if n >= 1_000_000_000_000 { return nil }
        if n == 0 { return [try a.req("0")] }
        if 1900 <= n, n <= 1999, digits.pyLen == 4 {
            return [try a.req("19") + a.req("hundred")] + (n % 100 != 0 ? [try a.req(String(n % 100))] : [])
        }
        var out: [String] = []
        for (scale, name) in [(1_000_000_000, "billion"), (1_000_000, "million"), (1000, "thousand")] {
            let q = n / scale
            n = n % scale
            if q != 0 {
                out += try group(q, pre: true)
                out.append(try a.req(name))
            }
        }
        if n != 0 { out += try group(n) }
        return out
    }

    func digits(_ d: String) throws -> [String] {
        let L = d.pyLen
        if L <= 3 {
            var z = L - d.lstrip("0").pyLen
            z = min(z, L - 1)
            let zeros = try (0..<z).map { _ in try a.req("0") }.joined()
            guard let rest = try integer(d.sl(z)) else { throw G2PError("type") }
            return [zeros] + rest
        }
        if L == 4 { return [try d.chars.map { try a.req($0) }.joined()] }
        var groups: [String] = []
        var rest = d
        while !rest.isEmpty {
            groups.insert(rest.sl(-3), at: 0)
            rest = rest.sl(nil, -3)
        }
        return try groups.map { try $0.chars.map { try a.req($0) }.joined() }
    }

    func number(_ s: String) throws -> [String]? {
        let (whole, _, frac) = s.partition(".")
        let digits = whole.rep(",", "")
        var out: [String]?
        if digits.pyLen > 1, digits.starts("0"), !whole.has(",") {
            out = try self.digits(digits)
        } else {
            out = try integer(digits)
        }
        guard var o = out else { return nil }
        if !frac.isEmpty {
            o = o + [try a.req(".")] + (try frac.chars.map { try a.req($0) })
        }
        return o
    }

    static func rightSuffix(_ n: Int) -> String {
        if 10 <= n % 100, n % 100 <= 20 { return "th" }
        return [1: "st", 2: "nd", 3: "rd"][n % 10] ?? "th"
    }

    func ordinal(_ n: Int, _ suffix: String) throws -> [String] {
        let r = n % 100
        if r == 0 { return (try integer(String(n)) ?? []) + [try a.req("ord:th")] }
        let head: [String]? = n - r != 0 ? try integer(String(n - r)) : []
        let whole = try a.req("ord:\(r)")
        let right = Numbers.SUFFIX_SOUND[Numbers.rightSuffix(r)]!
        if !whole.ends(right) { return (head ?? []) + [whole] }
        return (head ?? []) + [whole.sl(nil, -right.pyLen) + (try Numbers.SUFFIX_SOUND.req(suffix))]
    }

    func letters(_ run: String, first: Bool) -> [String]? {
        let names = run.chars.map { a["letter:" + $0.lower] }
        if names.contains(where: { $0 == nil }) { return nil }
        let n = names.map { $0! }
        let spelled = n.dropLast().map { $0.rep(PRIMARY, SECONDARY) }.joined()
        let tail = first && run.lower == "a" ? n.last!.rep(PRIMARY, SECONDARY) : n.last!
        return [spelled + tail]
    }

    func say(_ w: String) -> String? {
        do { return try sayImpl(w) } catch { return nil }
    }

    private func sayImpl(_ w: String) throws -> String? {
        let segs = NUM_SEG.findall(w.rep("−", "-"))
        var toks: [String] = []
        var glue = false
        var i = 0
        func appendPart(_ p: [String]) {
            var part = p
            if glue, !toks.isEmpty, !part.isEmpty {
                toks[toks.count - 1] += part[0]
                part = Array(part.dropFirst())
            }
            toks += part
            glue = false
        }
        while i < segs.count {
            let g = segs[i]
            let nxt = i + 1 < segs.count ? segs[i + 1] : ""
            let prev = i > 0 ? segs[i - 1] : ""
            if g.first1.pyIsDigit {
                var part: [String]?
                if prev == ":", g.pyLen == 2, g.starts("0") {
                    part = try g.chars.map { try a.req($0) }
                } else if nxt == ":", g.pyIsDigit {
                    part = try integer(g)
                } else if Numbers.ORD.contains(nxt), !g.has(".") {
                    part = try ordinal(try pyInt(g.rep(",", "")), nxt)
                    i += 1
                } else if nxt == "s", !g.has(".") {
                    guard let p = try number(g) else { return nil }
                    part = p + [try a.req("suffix:s")]
                    i += 1
                } else {
                    part = try number(g)
                }
                guard let p = part else { return nil }
                if glue, !toks.isEmpty, p.isEmpty { throw G2PError("index") }
                appendPart(p)
            } else if g.pyIsAlpha {
                var part: [String]?
                if prev == "-", g.pyLen > 1 {
                    part = word(g).map { [$0] }
                } else if g.pyLen > 1, g.pyIsLower, word(g) != nil, nxt == "-" || prev.isEmpty {
                    part = [word(g)!]
                } else if g.pyLen > 3, let y = word(g) {
                    part = [y]
                } else if g.pyLen <= 3 || g.pyIsUpper {
                    part = letters(g, first: toks.isEmpty)
                } else {
                    part = nil
                }
                guard let p = part else { return nil }
                appendPart(p)
            } else if (g == "'" || g == "’"), nxt == "s", !toks.isEmpty {
                toks.append(try a.req("suffix:s"))
                i += 1
            } else if ["$", "£", "€"].contains(g), toks.isEmpty {
                toks.append(try a.req(g))
            } else if g == "-" {
                if toks.isEmpty, nxt.first1.pyIsDigit {
                    toks.append(try a.req("minus"))
                } else if !toks.isEmpty, nxt.first1.pyIsDigit, prev.pyIsAlpha {
                    toks.append("")
                } else if !toks.isEmpty, nxt.first1.pyIsDigit {
                    toks.append(try a.req("-"))
                } else if !toks.isEmpty, nxt.pyIsAlpha {
                    glue = true
                } else if nxt.isEmpty {
                } else {
                    return nil
                }
            } else if ["%", "°", "/"].contains(g) {
                toks.append(try a.req(g))
            } else if g == ":" {
                if !(nxt.pyLen == 2 && nxt.pyIsDigit) { toks.append(try a.req(":")) }
            } else if g == "–" {
            } else {
                return nil
            }
            i += 1
        }
        return toks.isEmpty ? nil : link(toks)
    }

    func link(_ toks: [String]) -> String {
        var out: [String] = []
        for (i, t0) in toks.enumerated() {
            var t = t0
            let nxt = i + 1 < toks.count ? toks[i + 1] : ""
            let nb = bareStress(nxt)
            if t.ends("əɹ"), VOWELS.contains(nb.first1) { t += "ɹ" }
            out.append(t)
        }
        return out.joined(separator: " ")
    }
}

// MARK: - number words (text, before the lexicon)

func cardinal(_ n: Int) throws -> String {
    if n < 20 { return try ONES.req(n) }          // as ONES[n] in the reference, negative n included
    if n < 100 { return TENS[n / 10] + (n % 10 == 0 ? "" : "-" + ONES[n % 10]) }
    for (scale, name) in [(1_000_000_000, "billion"), (1_000_000, "million"), (1000, "thousand"), (100, "hundred")] where n >= scale {
        let q = n / scale, r = n % scale
        return try cardinal(q) + " " + name + (r == 0 ? "" : " " + cardinal(r))
    }
    throw G2PError("value")
}

func ordinalWords(_ n: Int) throws -> String {
    var words = try cardinal(n).splitOn(" ")
    let (head, _, l) = words[words.count - 1].rpartition("-")
    var last = l
    if let o = ORDINAL_WORDS[last] { last = o } else if last.ends("y") { last = last.sl(nil, -1) + "ieth" } else { last += "th" }
    words[words.count - 1] = (head.isEmpty ? "" : head + "-") + last
    return words.joined(separator: " ")
}

func pluralNumber(_ n: Int) throws -> String {
    if 1000 <= n, n <= 9999, n % 100 == 0, n % 1000 != 0 { return try cardinal(n / 100) + " hundreds" }
    if (1100 <= n && n <= 1999) || (2010 <= n && n <= 2099) { return try cardinal(n / 100) + " " + pluralNumber(n % 100) }
    let w = try cardinal(n)
    return w.ends("y") ? w.sl(nil, -1) + "ies" : w + "s"
}

func yearWords(_ y: Int) throws -> [String] {
    if (2000 <= y && y <= 2009) || y < 1000 || y > 2099 { return try cardinal(y).splitOn(" ") }
    let hi = y / 100, lo = y % 100
    if lo == 0 { return [try cardinal(hi), "hundred"] }
    return [try cardinal(hi)] + (lo < 10 ? ["oh", ONES[lo]] : [try cardinal(lo)])
}

func pairWords(_ n: Int) throws -> [String] {
    if n % 1000 == 0 { return try cardinal(n).splitOn(" ") }
    return 1000 <= n && n <= 9999 ? try yearWords(n) : try cardinal(n).splitOn(" ")
}

func digitWords(_ s: String, zero: String = "zero") throws -> [String] {
    try s.chars.filter { $0.pyIsDigit }.map { c in c == "0" ? zero : try ONES.req(try pyInt(c)) }
}

func romanValue(_ s: String) throws -> Int {
    let vals: [String: Int] = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000]
    let c = s.chars
    var total = 0
    for (k, ch) in c.enumerated() {
        let v = try vals.req(ch)
        let nv = k + 1 < c.count ? try vals.req(c[k + 1]) : 0
        total += nv > v ? -v : v
    }
    return total
}

func stripOkina(_ w0: String) -> String {
    let w = RX.get("(?<=\\w)[ʻ‘'’](?=\\w)").sub(w0) { _ in "" }
    let nfd = w.decomposedStringWithCanonicalMapping
    return String(scalars: nfd.unicodeScalars.filter { $0.properties.generalCategory != .nonspacingMark })
}

func isEmoji(_ w: String) -> Bool {
    guard !w.isEmpty else { return false }
    let all = w.unicodeScalars.allSatisfy { c in
        let cat = c.properties.generalCategory
        return cat == .otherSymbol || cat == .modifierSymbol || cat == .format || cat == .nonspacingMark
            || (0x1F000...0x1FAFF).contains(c.value) || c.value == 0xFE0F || c.value == 0x200D
    }
    let any = w.unicodeScalars.contains { (0x1F000...0x1FAFF).contains($0.value) || (0x2600...0x27BF).contains($0.value) }
    return all && any
}
