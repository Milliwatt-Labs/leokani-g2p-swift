// SPDX-License-Identifier: MIT
// Leokani G2P by Milliwatt Labs (milliwattlabs.com)
//
// The line front end (the same as leokani.py's): clean, clause chunks, pieces with respellings, silent characters.
import Foundation

/// code points with their combining marks (and ZWJ) attached, as the reference's clusters()
func clusters(_ s: String) -> [String] {
    var out: [String] = []
    for c in s.unicodeScalars {
        if !out.isEmpty, c.isMark || c.value == 0x200D { out[out.count - 1].unicodeScalars.append(c) } else { out.append(String(c)) }
    }
    return out
}

/// Drop markdown marks and fold whitespace.
public func clean(_ text: String) -> String {
    let a = RX.get("[*_`#>|]+").sub(text) { _ in " " }
    return RX.get("\\s+").sub(a) { _ in " " }.pyStrip
}

/// Clause chunks: break after . ! ? ; : (not after a title such as 'Dr.'), and after a comma once a chunk has 12
/// words. The first chunk needs 3 words.
public func chunks(_ text: String) -> [String] {
    var out: [String] = [], cur: [String] = []
    for w in text.splitOn(" ") where !w.isEmpty {
        cur.append(w)
        let end = w.last1
        let brk = "!?;:".has(end) || (end == "." && !TITLES.contains(w.lower.strip("(\"'").rstrip("."))) || (end == "," && cur.count >= 12)
        if brk, cur.count >= (out.isEmpty ? 3 : 1) {
            out.append(cur.joined(separator: " "))
            cur = []
        }
    }
    if !cur.isEmpty { out.append(cur.joined(separator: " ")) }
    return out.filter { $0.unicodeScalars.contains { $0.pyIsAlnum } }
}

func respell(_ word: String, _ prev: String?, _ nxt: [String]) -> String? {
    let w = word.lower, p = prev?.lower, n = nxt.map { $0.lower }
    let wq = w.rep("’", "'")
    if word.first1 == "I", let pr = PRONOUN[wq] {
        if let p, PRONOUN_AFTER.contains(p.rep("’", "'")) { return nil }
        return pr
    }
    if let nm = NAMES[w] { return nm }
    if w == "read" {
        if (p != nil && READ_PAST_BEFORE.contains(p!)) || n.contains(where: { READ_PAST_AFTER.contains($0) }) { return "red" }
    } else if w == "lead" {
        if (!n.isEmpty && LEAD_METAL.contains(n[0])) || p == "of" { return "led" }
    } else if w == "wind" || w == "winds" {
        let s = w == "winds" ? "s" : ""
        if !n.isEmpty, ["up", "down"].contains(n[0]) { return "wined" + s }
        if !n.isEmpty, WIND_OBJECT.contains(n[0]), p == nil || WIND_VERB_BEFORE.contains(p!) { return "wined" + s }
    } else if w == "lives" {
        if let p, LIVES_SUBJECT.contains(p) { return "livs" }
        if let p, let prev, !prev.isEmpty, prev.first1.pyIsUpper, !LIVES_OWNER.contains(p) { return "livs" }
    }
    if let p, YEAR_BEFORE.contains(p), w.pyLen == 4, w.pyIsAscii, w.pyIsDigit, let y = Int(w) {
        if (1100 <= y && y <= 1999) || (2010 <= y && y <= 2099) {
            let hi = y / 100, lo = y % 100
            return lo == 0 ? "\(hi) hundred" : lo < 10 ? "\(hi) oh \(lo)" : "\(hi) \(lo)"
        }
    }
    return nil
}

/// Words grouped into punctuation-free clauses, with the punctuation marks between them as their own pieces.
public func pieces(_ text: String) -> [String] {
    var words: [(String, String)] = []
    for t in text.words {
        var core = clusters(t)
        while let f = core.first, DROPPED.contains(f) { core.removeFirst() }
        var trail = ""
        while let last = core.last, DROPPED.contains(last) || PUNCT.contains(last) {
            if PUNCT.contains(last) {
                if last == ".", ABBREV.contains(core.joined().lower) { break }
                trail = last + trail
            }
            core.removeLast()
        }
        if !core.isEmpty, core.allSatisfy({ $0 == "-" }) {
            words.append(("", "—"))
            continue
        }
        words.append((core.joined(), trail))
    }
    var out: [String] = [], clause: [String] = []
    for (i, (word, punct)) in words.enumerated() {
        if !word.isEmpty {
            let prev: String? = i > 0 && words[i - 1].1.isEmpty ? words[i - 1].0 : nil
            var nxt: [String] = []
            if punct.isEmpty {
                for j in (i + 1)..<min(words.count, i + 5) {
                    nxt.append(words[j].0)
                    if !words[j].1.isEmpty { break }
                }
            }
            clause.append(respell(word, prev, nxt) ?? word)
        }
        if !punct.isEmpty {
            if !clause.isEmpty { out.append(clause.joined(separator: " ")) }
            clause = []
            out.append(punct.has("..") ? "…" : clusters(punct).prefix(2).joined())
        }
    }
    if !clause.isEmpty { out.append(clause.joined(separator: " ")) }
    return out
}

/// Characters espeak-ng speaks differently across platforms become spaces before each piece.
func desilence(_ piece: String) -> String {
    String(piece.unicodeScalars.map { c in SILENT.contains { $0.0 <= c.value && c.value <= $0.1 } ? " " : c }
        .reduce(into: String.UnicodeScalarView()) { $0.append($1) })
}
