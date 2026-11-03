// SPDX-License-Identifier: MIT
// Leokani G2P by Milliwatt Labs (milliwattlabs.com)
//
// Rewrites a line so the G2P reads it as a person would: money, phone numbers, times and dates, emails, URLs and
// handles, versions and IP addresses, units, fractions, ratios and ranges, Roman numerals, abbreviations, a few
// heteronyms and names. A line-for-line port of leokani_g2p.py's Normalizer; keep the two in step.
import Foundation

let UNIT_GLUED = Re(UNIT_GLUED_PATTERN)
let ROMAN = Re(ROMAN_PATTERN)
let NAMED_RANGE = Re(NAMED_RANGE_PATTERN)
private let VULGAR_MIXED = Re("(\\d)\\s*([" + VULGAR.map { $0.0 }.joined() + "])")
private let VULGAR_ANY = Re(VULGAR.map { $0.0 }.joined(separator: "|"))
private let VULGAR_MAP = Dictionary(uniqueKeysWithValues: VULGAR)

typealias Rule = (words: [String], used: Int, trail: String)

struct Tok {
    let core: String, trail: String, prev: String, prev2: String, prevEnd: Bool, nxt: String, nxtRaw: String
    let toks: [String], i: Int, pauses: Bool
}

final class Normalizer {
    let reading: (String) -> [String]
    let cased: (String) -> Bool
    let common: (String) -> Bool
    let lexicon: (String) -> Bool
    let letters: [String: String]
    var user: UserLexicon?
    private var userOn = true

    init(known: @escaping (String) -> Bool, letters: [String: String], cased: @escaping (String) -> Bool,
         common: @escaping (String) -> Bool, reading: @escaping (String) -> [String]) {
        lexicon = known; self.letters = letters; self.cased = cased; self.common = common; self.reading = reading
    }

    func known(_ w: String) -> Bool { SAY_AS[w] != nil || lexicon(w) }

    // MARK: helpers
    func spelled(_ w: String) -> Bool {
        let forms = reading(w)
        func bare(_ x: String) -> String { bareStress(x).rep(" ", "") }
        let l = w.chars.map { bare(letters[$0] ?? "?") }.joined()
        return forms.isEmpty || forms.contains { bare($0) == l }
    }

    func letter(_ c: String) -> String {
        if let ph = letters[c.lower], !ph.isEmpty { return c.upper + PH + ph }
        return c.upper
    }

    func spell(_ s: String) throws -> [String] {
        try s.chars.filter { $0.pyIsAlnum && $0.pyIsAscii }.map { c in c.pyIsAlpha ? letter(c) : try ONES.req(try pyInt(c)) }
    }

    func segment(_ run: String) -> [String]? {
        let low = run.lower
        let lc = low.sc
        let n = lc.count
        var best = [[String]?](repeating: nil, count: n + 1)
        best[0] = []
        if n >= 1 {
            for i in 1...n {
                for j in max(0, i - 20)..<i {
                    let w = String(scalars: lc[j..<i])
                    let wl = i - j
                    guard let bj = best[j], wl >= 3 || (j == 0 && wl == 1 && i < n) else { continue }
                    if wl > 1, !known(w) { continue }
                    let cand = bj + [w]
                    if best[i] == nil || cand.count < best[i]!.count { best[i] = cand }
                }
            }
        }
        if let out = best[n], out.count > 1 { return out }
        return nil
    }

    func sayRun(_ run: String) throws -> [String] {
        var out: [String] = []
        for g in RX.get("[A-Za-z]+|\\d+").findall(run) {
            if g.pyIsDigit {
                out += try digitWords(g)
            } else if known(g.lower) {
                out.append(Normalizer.word(g.lower))
            } else if let seg = segment(g) {
                out += seg.map { $0.pyLen == 1 ? letter($0) : Normalizer.word($0) }
            } else if g.pyLen > 3, rs("[aeiouy]", g.lower) {
                out.append(g.lower)
            } else {
                out += try spell(g)
            }
        }
        return out
    }

    static func word(_ w: String) -> String {
        if let s = SAY_AS[w] { return w + PH + s }
        return w
    }

    func sayParts(_ s: String) throws -> [String] {
        var out: [String] = []
        for part in RX.get("([._+\\-/~=?&#:%])").split(s) where !part.isEmpty {
            if let w = SEP_WORDS[part] { out.append(w) } else { out += try sayRun(part) }
        }
        return out
    }

    func domain(_ d: String) throws -> [String] {
        let labels = d.splitOn(".")
        var out: [String] = []
        for (i, lab) in labels.enumerated() {
            if i > 0 { out.append("dot") }
            let low = lab.lower
            if i == labels.count - 1, TLDS.contains(low) {
                if let s = TLD_SAY[low] { out.append(s) } else { out += try spell(low) }
            } else if low == "www" {
                out += try spell("www")
            } else {
                out += try sayParts(lab)
            }
        }
        return out
    }

    func money(_ sign: String?, _ cur: String, _ whole0: String?, _ frac: String?, _ scale: String?, _ nextScale: String?) throws -> [String] {
        let (one, many, cent, cents) = try CURRENCY.req(cur)
        let out: [String] = (sign ?? "").isEmpty ? [] : ["minus"]
        let whole = (whole0 ?? "").isEmpty ? "0" : whole0!
        let wd = whole.rep(",", "")
        let n = wd.isEmpty ? 0 : try pyInt(wd)
        let sc = SCALES[scale ?? ""] ?? nextScale
        if let sc, !sc.isEmpty { return out + [whole + (frac ?? ""), sc, many] }
        let f = frac ?? ""
        if !f.isEmpty, f.pyLen == 3, !cents.isEmpty {
            let c = try pyInt(f.sl(1))
            if n == 0, c != 0 { return out + [String(c), c == 1 ? cent : cents] }
            if c == 0 { return out + [whole, n == 1 ? one : many] }
            if cur == "£" { return out + [whole, n == 1 ? one : many, String(c)] }
            return out + [whole, n == 1 ? one : many, "and", String(c), c == 1 ? cent : cents]
        }
        if !f.isEmpty { return out + [whole + f, many] }
        return out + [whole, n == 1 && cur != "¥" ? one : many]
    }

    func phone(_ groups: [String], _ pauses: Bool, plus: Bool = false) throws -> [String] {
        var out: [String] = plus ? ["plus"] : []
        for (i, g) in groups.enumerated() {
            var w = g.pyIsDigit ? try digitWords(g) : [g.lower]
            if g == "800", i == 1, groups[0] == "1" { w = ["eight", "hundred"] }
            if pauses, i < groups.count - 1 {
                guard !w.isEmpty else { throw G2PError("index") }
                w[w.count - 1] += ","
            }
            out += w
        }
        return out
    }

    func time(_ h: String, _ m: String, _ s: String?, _ ampm: String?) throws -> [String]? {
        let hh = try pyInt(h), mm = try pyInt(m)
        if hh > 24 || mm > 59 { return nil }
        if let s {
            let ss = try pyInt(s)
            if ss > 59 { return nil }
            var out = [String(hh)] + (0 < mm && mm < 10 ? ["oh", String(mm)] : mm != 0 ? [m] : ["hundred"])
            out += 0 < ss && ss < 10 ? ["oh", String(ss)] : ss != 0 ? [s] : ["hundred"]
            return out
        }
        var out = [String(hh)]
        let ap = ampm ?? ""
        if mm == 0 {
            out += hh >= 13 || (h.starts("0") && ap.isEmpty) ? ["hundred"] : []
        } else if mm < 10 {
            out += ["oh", String(mm)]
        } else {
            out += [m]
        }
        if !ap.isEmpty { out += [letter(ap), "M"] }
        return out
    }

    static func fraction(_ n: Int, _ d: Int) throws -> [String]? {
        let one: String, many: String
        if d == 2 { (one, many) = ("half", "halves") } else if d == 4 { (one, many) = ("quarter", "quarters") }
        else if [3, 5, 6, 7, 8, 9, 10, 12, 16, 32, 64, 100].contains(d) {
            one = try ordinalWords(d)
            many = one + "s"
        } else { return nil }
        if !(0 < n && n < d) { return nil }
        return [try cardinal(n), n == 1 ? one : many]
    }

    // MARK: the line
    func callAsFunction(_ text0: String, pauses: Bool = true) -> String {
        var text = text0.rep("\u{2011}", "-").rep("\u{2010}", "-")
        text = VULGAR_MIXED.sub(text) { m in m.s(1) + " " + VULGAR_MAP[m.s(2)]! + " " }
        text = VULGAR_ANY.sub(text) { m in " " + VULGAR_WORDS[m.s(0)]! + " " }
        text = NAMED_RANGE.sub(text) { m in " " + m.s(1) + " " }
        let toks = text.words
        var out: [String] = []
        var i = 0
        while i < toks.count {
            let (w, used) = token(toks, i, pauses)
            out += w
            i += used
        }
        return out.joined(separator: " ")
    }

    static func split(_ t: String) -> (String, String, String) {
        let s = t.sc
        var a = 0
        let open = Set(OPEN.unicodeScalars), close = Set(CLOSE.unicodeScalars)
        while a < s.count, open.contains(s[a]), !rt("^['’]\\d0s", String(scalars: s[a...])) { a += 1 }
        var b = s.count
        while b > a, close.contains(s[b - 1]) { b -= 1 }
        return (String(scalars: s[..<a]), String(scalars: s[a..<b]), String(scalars: s[b...]))
    }

    func token(_ toks: [String], _ i: Int, _ pauses: Bool) -> ([String], Int) {
        let t = toks[i]
        if t.has(PH) { return ([t], 1) }
        let (lead, core, trail) = Normalizer.split(t)
        if let user, userOn, !core.isEmpty, let hit = user.rewrite(core) {
            var words: [String]
            switch hit {
            case .phonemes(let ph): words = [core + PH + ph]
            case .say(let text):
                userOn = false
                words = self(text, pauses: pauses).splitOn(" ").filter { !$0.isEmpty }
                userOn = true
            }
            return Normalizer.finish(words, 1, lead, core, trail)
        }
        let prev = i > 0 ? Normalizer.split(toks[i - 1]).1 : ""
        let prevEnd = i == 0 || ".!?:;".has(toks[i - 1].last1) && !toks[i - 1].last1.isEmpty
        let prev2 = i > 1 ? Normalizer.split(toks[i - 2]).1.lower : ""
        let nxtRaw = i + 1 < toks.count ? toks[i + 1] : ""
        let nxt = Normalizer.split(nxtRaw).1
        let c = Tok(core: core, trail: trail, prev: prev, prev2: prev2, prevEnd: prevEnd, nxt: nxt, nxtRaw: nxtRaw,
                    toks: toks, i: i, pauses: pauses)
        var res: Rule?
        do { res = try rewrite(c) } catch { res = nil }       // never fail a line: keep the token as written
        guard let r = res else { return ([t], 1) }
        return Normalizer.finish(r.words, r.used, lead, core, r.trail)
    }

    static func finish(_ words0: [String], _ used: Int, _ lead0: String, _ core: String, _ trail: String) -> ([String], Int) {
        var lead = lead0
        if lead.has("("), !trail.has(")"), used > 1 || core.has(")") { lead = lead.rep("(", "") }
        if words0.isEmpty {
            return (trail.strip("\"'”’)]}»").isEmpty ? [] : [lead.strip("\"'“‘([{«") + trail], used)
        }
        var words: [String] = []
        for w in words0 {
            if !w.has(PH) || !w.has(" ") { words.append(w); continue }
            let parts = w.split1(PH)
            for p in parts[1].splitOn(" ") { words.append(parts[0] + PH + p) }
        }
        words[0] = lead + words[0]
        words[words.count - 1] = words[words.count - 1] + trail
        return (words, used)
    }

    func rewrite(_ c: Tok) throws -> Rule? {
        if c.core.isEmpty { return nil }
        if let r = try lettersFirst(c) { return r }
        if let r = try more2(c) { return r }
        if let r = try more(c) { return r }
        if let r = try more3(c) { return r }
        if let r = try basic(c) { return r }
        return try capitals(c)
    }

    func sub(_ text: String, _ pauses: Bool) -> [String] { self(text, pauses: pauses).splitOn(" ") }

    // MARK: second-round rules
    func more(_ c: Tok) throws -> Rule? {
        let core = c.core, trail = c.trail, prev = c.prev, nxt = c.nxt, toks = c.toks, i = c.i, pauses = c.pauses
        let low = core.lower, pl = prev.lower, nl = nxt.lower
        func isNum(_ x: String) -> Bool { rt("^-?\\d[\\d,]*(\\.\\d+)?$", x) }
        if rs("[–—-]", core), rs("\\d", core), !P_PHONE.test(core), !P_TOLLWORD.test(core),
           !rt("^[\\d,.]+([–-][\\d,.]+)+$", core), !P_DATE_ISO.test(core), !P_VERSION_DASH.test(core),
           !rt("^\\d{1,2}:\\d{2}[-–]\\d{1,2}:\\d{2}$", core) {
            let parts = RX.get("[–—-]").split(core)
            func timey(_ p: String) -> Bool { P_TIME.test(p) || P_TIME_AMPM.test(p) || ["noon", "midnight"].contains(p.lower) }
            func money(_ p: String) -> Bool { P_MONEY.test(p) }
            if parts.count == 2, parts.allSatisfy({ !$0.isEmpty }), parts.allSatisfy(timey) || parts.allSatisfy(money) {
                var a = sub(parts[0], pauses)
                let b = sub(parts[1], pauses)
                if money(parts[0]), try a.req(-1) == b.req(-1) { a = Array(a.dropLast()) }
                return (a + ["to"] + b, 1, trail)
            }
            if parts.allSatisfy({ !$0.isEmpty }), parts.contains(where: { money($0) || P_TIME_AMPM.test($0) }) {
                var out: [String] = []
                for p in parts { out += sub(p, pauses) }
                return (out, 1, trail)
            }
        }
        if let m = rm("^([$€£¥₹][\\d,.]+[kKmMbB]?)/([A-Za-z]+)$", core), let pu = PER_UNIT[m.s(2).lower] {
            return (sub(m.s(1), pauses) + pu.splitOn(" "), 1, trail)
        }
        if let m = P_MONEY.match(core), !m.s(3).isEmpty, m.s(4).isEmpty, m.s(5).isEmpty, ATTRIBUTIVE.contains(nl) {
            return ((m.s(1).isEmpty ? [] : ["minus"]) + [m.s(3), try CURRENCY.req(m.s(2)).0], 1, trail)
        }
        if let m = rm("^\\(?(\\d{3})\\)(\\d{3})-(\\d{4})$", core) {
            return (try phone([m.s(1), m.s(2), m.s(3)], pauses), 1, trail)
        }
        if let m = rm("^(?:x|ext\\.?)(\\d{1,5})$", core, true) {
            let d = m.s(1)
            return (["extension"] + (d.pyLen > 2 ? try digitWords(d) : [d]), 1, trail)
        }
        if low == "ext", trail.starts("."), nxt.first1.pyIsDigit { return (["extension"], 1, trail.sl(1)) }
        if let m = rm("^\\*(\\d{1,4})#?$", core) {
            return (["star"] + (try digitWords(m.s(1))) + (core.ends("#") ? ["pound"] : []), 1, trail)
        }
        if core == "#", ["press", "then", "hit", "dial", "enter", "and", "or"].contains(pl) || nxt.isEmpty { return (["pound"], 1, trail) }
        if core == "*", !(isNum(prev) && isNum(nxt)) { return (["star"], 1, trail) }
        if rt("^[0-2]\\d[0-5]\\d$", core), ["hours", "hrs", "hr", "h"].contains(nl) {
            let h = try pyInt(core.sl(nil, 2)), mm = try pyInt(core.sl(2))
            return ((core.first1 == "0" ? ["oh"] : []) + [try cardinal(h)] +
                    (mm == 0 ? ["hundred"] : mm < 10 ? ["oh", ONES[mm]] : [try cardinal(mm)]), 1, trail)
        }
        if let m = rm("^(?:https?://)?(localhost|(?:[\\w-]+\\.)+[a-z]{2,}|\\d{1,3}(?:\\.\\d{1,3}){3}):(\\d{2,5})(/\\S*)?$", core) {
            let host = m.s(1), port = m.s(2)
            var words = P_IPV4.test(host) ? try ip(host) : host == "localhost" ? ["local", "host"] : try domain(host)
            let pc = port.chars
            if port.pyLen == 4, port.sl(1) != "000", try pyInt(port) < 2100 {
                words += ["colon"] + (try pairWords(try pyInt(port)))
            } else if port.pyLen == 4, pc[2] != "0", port.sl(1) != "000" {
                words += ["colon", port.sl(nil, 2), port.sl(2)]
            } else {
                words += ["colon", port]
            }
            for seg in (m.g(3) ?? "").splitOn("/").dropFirst() { words += ["slash"] + (seg.isEmpty ? [] : try sayParts(seg)) }
            return (words, 1, trail)
        }
        if low.starts("ftp://"), core.pyLen > 6 {
            return ((try spell("FTP")) + ["colon", "slash", "slash"] + sub(core.sl(6), pauses), 1, trail)
        }
        if let m = rm("^([vV])?(\\d+)\\.(\\d{2,3}|x)$", core) {
            let g3 = m.s(3)
            if VERSION_CUE.contains(pl) || m.g(1) != nil || g3 == "x" ||
                (g3.ends("0") && !g3.starts("0") && UNITS[nl] == nil && !isNum(prev) &&
                 !["is", "of", "at", "was", "by", "about", "gpa", "score"].contains(pl)) {
                let minor = g3 == "x" ? [letter("x")] : [g3]
                return ((m.g(1) != nil ? ["version"] : []) + [m.s(2), "point"] + minor, 1, trail)
            }
        }
        if let m = P_VERSION_DASH.match(core) {
            var words: [String] = []
            for (k, x) in m.s(1).splitOn(".").enumerated() { words += (k > 0 ? ["point"] : []) + [x] }
            for part in m.s(2).splitOn("-").dropFirst() { words += ["dash"] + (part.isEmpty ? [] : sub(part, pauses)) }
            return (words, 1, trail)
        }
        if rt("^\\d+[A-Z]+\\d+[A-Z0-9]*$", core), core.pyLen >= 4 {
            var words: [String] = []
            for g in RX.get("\\d+|[A-Z]+").findall(core) {
                words += g.pyIsDigit ? (g.pyLen <= 2 ? [g] : try digitWords(g)) : try spell(g)
            }
            return (words, 1, trail)
        }
        if core.pyLen >= 8, rt("^[0-9a-fA-F]+$", core), rs("\\d", core), rs("[a-fA-F]", core) {
            return (try spell(core), 1, trail)
        }
        if rt("^\\d{2,4}$", core) {
            let near = toks[max(0, i - 2)..<min(toks.count, i + 3)].map { Normalizer.split($0).1 }
            if near.filter({ rt("^(\\d{4}|[A-Z]{2}\\d{2})$", $0) }).count >= 3 {
                var w = try digitWords(core)
                if pauses, trail.isEmpty, i + 1 < toks.count { w[w.count - 1] += "," }
                return (w, 1, trail)
            }
        }
        if rt("^[A-Z]{2}\\d{2}$", core), rt("^\\d{4}$", nxt) {
            var w = (try spell(core.sl(nil, 2))) + (try digitWords(core.sl(2)))
            if pauses, trail.isEmpty { w[w.count - 1] += "," }
            return (w, 1, trail)
        }
        if rt("^1[1-9]\\d\\d$", core), !core.ends("00"), i > 0,
           MONTHS.contains(prev) || (MONTH_ABBR[pl] != nil && prev.firstIsUpper) ||
            rt("^\\d{1,2}(st|nd|rd|th)?,$", toks[i - 1]) || rt("^(\\w+ )?\\w+(st|nd|rd|th),$", toks[i - 1]) {
            return (try yearWords(try pyInt(core)), 1, trail)
        }
        if rt("^\\d{1,2}$", core), (1...31).contains(try pyInt(core)), MONTHS.contains(prev) || (MONTH_ABBR[pl] != nil && prev.firstIsUpper) {
            if UNITS[nl] == nil, !["percent", "degrees", "hours", "minutes", "days", "people", "times"].contains(nl) {
                return ([try ordinalWords(try pyInt(core))], 1, trail)
            }
        }
        if rt("^\\d{1,2}$", core), (1...31).contains(try pyInt(core)), MONTHS.contains(nxt), !["the", "of"].contains(pl), !isNum(prev) {
            return (["the", try ordinalWords(try pyInt(core)), "of"], 1, trail)
        }
        if let dir = DIRECTIONS[low], core.pyIsUpper {
            if core.pyLen == 2, STREET_WORDS.contains(pl.rstrip(".")) || STREET_ABBR.values.contains(prev) { return ([dir], 1, trail) }
            if core.pyLen == 1, trail.starts("."), nxt.firstIsUpper || rt("^\\d+(st|nd|rd|th)$", nxt) { return ([dir], 1, trail.sl(1)) }
        }
        if ["ste", "hwy", "rte", "ave", "blvd"].contains(low), core.firstIsUpper,
           nxt.firstIsDigit || (["ave", "blvd"].contains(low) && prev.firstIsUpper) {
            let word = ["ste": "Suite", "hwy": "Highway", "rte": "Route", "ave": "Avenue", "blvd": "Boulevard"][low]!
            var tr = trail
            if tr.starts("."), tr.pyLen > 1 || (!nxt.isEmpty && !nxt.firstIsUpper) { tr = tr.sl(1) }
            return ([word], 1, tr)
        }
        if let st = STATES[core], rt("^\\d{5}(-\\d{4})?$", nxt), i > 0, toks[i - 1].ends(",") {
            let z = Normalizer.split(c.nxtRaw)
            return (st.splitOn(" ") + (try digitWords(z.1)), 2, z.2)
        }
        if let m = rm("^I-(\\d{1,3})$", core) {
            let d = m.s(1), dc = d.chars
            let rest: [String] = d.pyLen <= 2 ? [d] : [ONES[try pyInt(dc[0])]] + (dc[1] == "0" ? ["oh", ONES[try pyInt(dc[2])]] : [d.sl(1)])
            return ([letter("I")] + rest, 1, trail)
        }
        if rt("^[1-9]\\d{3}$", core) {
            let cue = ["box", "suite", "ste", "room", "unit", "apt", "apartment"].contains(pl)
            let street = nxt.firstIsUpper && toks[min(toks.count, i + 1)..<min(toks.count, i + 4)].contains {
                STREET_WORDS.contains(Normalizer.split($0).1.lower.rstrip("."))
            }
            if cue || street { return (try pairWords(try pyInt(core)), 1, trail) }
        }
        let inch = !trail.first1.isEmpty && "\"”″".has(trail.first1)
        if let m = rm("^(\\d{1,2})[′'’](\\d{1,2})$", core), inch { return ([m.s(1), "foot", m.s(2)], 1, trail.sl(1)) }
        if rt("^\\d+(\\.\\d+)?$", core), inch, ["a", "an", "the"].contains(prev) ||
            ["bolt", "screw", "pipe", "screen", "display", "tv", "monitor", "wide", "long", "tall", "deep", "thick", "of", "nail"].contains(nl) {
            return ([core, core == "1" || ["a", "an", "the"].contains(prev) ? "inch" : "inches"], 1, trail.sl(1))
        }
        if let m = rm("^(\\d{1,3})/(\\d{1,3})$", core), inch, let fr = try Normalizer.fraction(try pyInt(m.s(1)), try pyInt(m.s(2))) {
            return (fr + ["inch"], 1, trail.sl(1))
        }
        if let m = rm("^(-?\\d+(?:\\.\\d+)?)[eE]([-+]?)(\\d{1,3})$", core) {
            return ([m.s(1), "times", "ten", "to", "the"] + (m.s(2) == "-" ? ["minus"] : []) + [m.s(3)], 1, trail)
        }
        if let m = rm("^(\\d+(?:\\.\\d+)?)-([A-Za-zµμ]+)$", core), let u = UNITS[m.s(2)] {
            return ([m.s(1)] + u.0.splitOn(" "), 1, trail)
        }
        if core == "I", prev.firstIsUpper, REGNAL.contains(pl),
           nl.ends("ed") || ["was", "had", "is", "of", "and", "became", "died", "who", "'s", "reigned", "ruled"].contains(nl) {
            return (["the", "first"], 1, trail)
        }
        if core == "I", ROMAN_CUE.contains(pl), prev.firstIsUpper { return (["one"], 1, trail) }
        if core.pyIsLower, core.pyLen >= 2, ROMAN.test(core.upper), ROMAN_CUE.contains(pl) {
            return ([try cardinal(try romanValue(core.upper))], 1, trail)
        }
        if core.starts("M"), core.pyLen >= 4, ROMAN.test(core) {
            let v = try romanValue(core)
            if 1000 <= v, v <= 2099 { return (try yearWords(v), 1, trail) }
        }
        if core.pyLen == 2, core.pyIsUpper, core.pyIsAlpha, core.pyIsAscii, !cased(core), !common(low), !ROMAN.test(core),
           !spelled(low), !(i > 0 && toks[i - 1].pyIsUpper && toks[i - 1].pyIsAlpha && toks[i - 1].pyLen > 3) {
            return (try spell(core), 1, trail)
        }
        if rt("^(?:[A-Za-z]{1,2}\\.)+[A-Za-z]{1,2}$", core), trail.starts("."), !["e.g", "i.e", "a.m", "p.m"].contains(low),
           core.chars.contains(where: { $0.pyIsLower }) {
            return (try spell(core.rep(".", "")), 1, trail.pyLen > 1 ? trail.sl(1) : trail)
        }
        if ["WHO", "IT", "AM", "OR", "IS", "AS"].contains(core), pl == "the" { return (try spell(core), 1, trail) }
        if low == "minute", ["is", "are", "was", "were", "very", "so", "quite", "extremely", "too", "seemed", "looked"].contains(pl) ||
            ["details", "detail", "amounts", "amount", "traces", "trace", "particles", "quantities", "changes", "differences",
             "fraction", "portion", "particle"].contains(nl) {
            return ([core + PH + ADJ_FORMS["minute"]!], 1, trail)
        }
        if low == "content", ["with", "to"].contains(nl), ["seemed", "seem", "seems", "feel", "felt", "feels", "be", "been", "is",
            "was", "are", "were", "am", "remain", "remained", "quite", "very", "perfectly", "more", "less", "not", "looked",
            "looks"].contains(pl) {
            return ([core + PH + ADJ_FORMS["content"]!], 1, trail)
        }
        if low == "fl", trail.starts("."), rt("^\\d+(st|nd|rd|th)$", prev) { return (["floor"], 1, trail.sl(1)) }
        return nil
    }

    // MARK: third-round rules
    func more2(_ c: Tok) throws -> Rule? {
        let core = c.core, trail = c.trail, prev = c.prev, prev2 = c.prev2, nxt = c.nxt, toks = c.toks, i = c.i, pauses = c.pauses
        let low = core.lower, pl = prev.lower, nl = nxt.lower
        func isNum(_ x: String) -> Bool { rt("^-?\\d[\\d,]*(\\.\\d+)?$", x) }
        if let s = SHORTHAND_CASED[core], pl != "the" { return (s.splitOn(" "), 1, trail) }
        if let s = SHORTHAND[low], !core.pyIsUpper, pl != "the", low != "re" || trail.starts(":") { return (s.splitOn(" "), 1, trail) }
        if let w = ["w/": ["with"], "w/o": ["without"], "b/c": ["because"]][low] { return (w, 1, trail) }
        if ["→", "->", "=>"].contains(core) { return (["to"], 1, trail) }
        if core == "@", !prev.isEmpty, !nxt.isEmpty { return (["at"], 1, trail) }
        if core == "St", !trail.starts("."), prev.firstIsUpper, prev.pyIsAlpha, !trail.isEmpty || nxt.isEmpty || nxt.firstIsLower {
            return (["Street"], 1, trail)
        }
        if rt("^[1-9]\\d{2}[A-Z]?$", core), ["room", "rm", "suite", "ste", "gate", "apt", "apartment", "unit", "flight"].contains(pl.rstrip(".")) {
            let d = core.sl(nil, 3), dc = d.chars
            let tail = try spell(core.sl(3))
            let mid: [String] = d.sl(1) == "00" ? ["hundred"] : dc[1] == "0" ? ["oh", ONES[try pyInt(dc[2])]] : [d.sl(1)]
            return ([ONES[try pyInt(dc[0])]] + mid + tail, 1, trail)
        }
        if let m = rm("^([A-Z]{2,4})(?:→|->)([A-Z]{2,4})$", core) {
            return ((try spell(m.s(1))) + ["to"] + (try spell(m.s(2))), 1, trail)
        }
        if ["–", "-", "—"].contains(core), !prev.isEmpty, !nxt.isEmpty {
            if DAY_ABBR[pl.rstrip(".")] != nil || DAY_ABBR.values.contains(prev),
               DAY_ABBR[nl.rstrip(".")] != nil || DAY_ABBR.values.contains(nxt) { return (["through"], 1, trail) }
            if prev.firstIsDigit || MONTH_ABBR[pl.rstrip(".")] != nil, nxt.firstIsDigit || MONTH_ABBR[nl.rstrip(".")] != nil {
                return (["to"], 1, trail)
            }
        }
        if let day = DAY_ABBR[low], core.firstIsUpper, core.pyIsAlpha,
           nxt.firstIsDigit || DAY_ABBR[nl] != nil || ["–", "-"].contains(nxt) || (trail == "," && i + 1 < toks.count) {
            return ([day], 1, trail)
        }
        if let m = rm("^([A-Z][a-z]{2})[–-]([A-Z][a-z]{2})$", core), let a = DAY_ABBR[m.s(1).lower], let b = DAY_ABBR[m.s(2).lower] {
            return ([a, "through", b], 1, trail)
        }
        if let m = rm("^(\\d{1,2})/(\\d{1,2})$", core) {
            let a = try pyInt(m.s(1)), b = try pyInt(m.s(2))
            if (1...12).contains(a), (1...31).contains(b), DAY_ABBR.values.contains(prev) || DAY_ABBR[pl.rstrip(".,")] != nil ||
                ["on", "by", "due", "until", "till", "from", "before", "after", "dated", "thru"].contains(pl) {
                return ([MONTHS[a - 1], try ordinalWords(b)], 1, trail)
            }
        }
        if let mo = MONTH_ABBR[low.rstrip(".")], core.firstIsUpper, rt("^\\d{1,2}(st|nd|rd|th)$", prev) {
            return (["of", MONTHS[mo - 1]], 1, trail.starts(".") ? trail.sl(1) : trail)
        }
        if let z = ZONES[core], P_TIME.test(prev) || rt("^(?i:[ap]\\.?m\\.?)$", prev) || ["AM", "PM"].contains(prev) {
            return (z.splitOn(" "), 1, trail)
        }
        if let m = rm("^(\\d{1,2}):(\\d{2})([ap])$", core) {
            return (try time(m.s(1), m.s(2), nil, m.s(3)) ?? [], 1, trail)   // None -> the token is dropped, as in the reference
        }
        if let m = rm("^(\\d{1,2})(?::(\\d{2}))?[–-](\\d{1,2})(?::(\\d{2}))?$", core),
           m.g(2) != nil || m.g(4) != nil, try pyInt(m.s(1)) <= 24, try pyInt(m.s(3)) <= 24, !prev.firstIsUpper {
            let a = try time(m.s(1), m.g(2) ?? "00", nil, nil) ?? [m.s(1)]
            let b = try time(m.s(3), m.g(4) ?? "00", nil, nil) ?? [m.s(3)]
            return (a.filter { $0 != "hundred" } + ["to"] + b.filter { $0 != "hundred" }, 1, trail)
        }
        if let m = rm("^(\\d+(?:\\.\\d+)?)(h|hr|m|min|s)$", core) {
            let n = m.s(1), u = m.s(2)
            if ["h", "hr"].contains(u) { return ([n, n == "1" ? "hour" : "hours"], 1, trail) }
            if u == "min" || (u == "m" && rt("^\\d+(h|hr)$", prev)) { return ([n, n == "1" ? "minute" : "minutes"], 1, trail) }
            if u == "s", rt("^\\d+(m|min)$", prev) { return ([n, n == "1" ? "second" : "seconds"], 1, trail) }
            if u == "m", (["the", "a", "ran", "run", "runs", "swam", "swim", "won", "in", "over", "under", "about", "climbed", "dove",
                           "fell", "jumped"].contains(pl) && !["for", "in", "dollars", "people", "users"].contains(nl)) ||
                ["race", "dash", "sprint", "freestyle", "hurdles", "relay", "run", "swim", "high", "deep", "long", "tall", "wide",
                 "away", "above", "below"].contains(nl) {
                return ([n, n == "1" ? "meter" : "meters"], 1, trail)
            }
        }
        if let m = rm("^([$€£¥]?)(\\d[\\d,]*(?:\\.\\d+)?)\\+$", core) {
            if !m.s(1).isEmpty { return (sub(m.s(1) + m.s(2), pauses) + ["or", "more"], 1, trail) }
            return (["more", "than", m.s(2)], 1, trail)
        }
        if let m = P_MONEY.match(core), !m.s(3).isEmpty, m.s(4).isEmpty, m.s(5).isEmpty, ["a", "an"].contains(pl), nxt.firstIsLower,
           !["a", "an", "the", "and", "or", "for", "per", "each", "to"].contains(nl) {
            return ([m.s(3), try CURRENCY.req(m.s(2)).0], 1, trail)
        }
        if rt("^\\d{4}$", core), pl == "ending" || (pl == "in" && prev2 == "ending") { return (try digitWords(core), 1, trail) }
        if rt("^\\d{5,6}$", core), pl == "to", toks[max(0, i - 4)..<i].contains(where: { Normalizer.split($0).1.lower == "text" }) {
            return (try digitWords(core), 1, trail)
        }
        if rt("^\\d{5}$", core), nxt.firstIsUpper, i > 0, toks[i - 1].ends(",") { return (try digitWords(core), 1, trail) }
        if let m = rm("^(?i:win)(\\d{1,2})$", core) { return (["Windows", m.s(1)], 1, trail) }
        if let m = rm("^([a-z]{1,4})(\\d{1,6})$", core), !["x", "ext"].contains(m.s(1)), !known(low),
           m.s(1).pyLen <= 3 || !known(m.s(1)) {
            let d = m.s(2)
            return ((try spell(m.s(1))) + (d.pyLen <= 2 ? [d] : try digitWords(d)), 1, trail)
        }
        if ["N", "S", "E", "W"].contains(core), isNum(prev),
           ["hwy", "highway", "route", "rte", "interstate", "i", "us", "sr"].contains(prev2) || rt("^\\d+(st|nd|rd|th)$", nxt) ||
            (nxt.firstIsUpper && nxt.pyLen > 2) {
            return ([try DIRECTIONS.req(low)], 1, trail)
        }
        if ["rm", "apt", "bldg", "fl"].contains(low), core.firstIsUpper, nxt.firstIsDigit || nxt.starts("#") {
            let word = ["rm": "Room", "apt": "Apartment", "bldg": "Building", "fl": "Floor"][low]!
            return ([word], 1, trail.starts(".") ? trail.sl(1) : trail)
        }
        if low == "approx", nxt.firstIsDigit || (!nxt.first1.isEmpty && "$~".has(nxt.first1)) {
            return (["approximately"], 1, trail.starts(".") ? trail.sl(1) : trail)
        }
        let fracWord = ["half", "quarter", "third", "eighth", "quarters", "thirds", "eighths"].contains(pl)
        if let u = UNITS[core], !["m", "g", "L", "W", "V", "s"].contains(core), P_FRACTION.test(prev) || rt("^\\d+[–-]\\d+$", prev) || fracWord {
            let one = P_FRACTION.test(prev) || ["half", "quarter", "third", "eighth"].contains(pl)
            return ((one ? u.0 : u.1).splitOn(" "), 1, trail)
        }
        if core == "A", LETTER_CUE.contains(pl), prev.firstIsUpper { return ([letter("A")], 1, trail) }
        if ["V", "X"].contains(core), REGNAL.contains(pl), prev.firstIsUpper { return (["the", try ordinalWords(try romanValue(core))], 1, trail) }
        if ["IV", "VI", "IX", "XI"].contains(core), prev.firstIsUpper, prev.pyIsAlpha, !prev.pyIsUpper {
            let v = try romanValue(core)
            return (REGNAL.contains(pl) ? ["the", try ordinalWords(v)] : [try cardinal(v)], 1, trail)
        }
        if core == "Read", i == 0 || (".!?:;".has(toks[i - 1].last1) && !toks[i - 1].last1.isEmpty), OBJECTS.contains(nl) || nxt.firstIsUpper {
            return ([core + PH + "ɹˈid"], 1, trail)
        }
        let plain = stripOkina(core)
        if plain != core || !plain.unicodeScalars.elementsEqual(core.unicodeScalars) {
            if !plain.unicodeScalars.elementsEqual(core.unicodeScalars), plain.pyIsAscii, plain.pyIsAlpha, !known(low),
               SAY_AS[plain.lower] == nil, known(plain.lower) || plain.pyLen == 1 {
                return ([plain], 1, trail)
            }
        }
        if core.pyLen == 3, core.pyIsUpper, core.pyIsAlpha, core.pyIsAscii, !cased(core), !common(low), !ACRONYM_WORDS.contains(core),
           !ROMAN.test(core), !spelled(low), !(i > 0 && toks[i - 1].pyIsUpper && toks[i - 1].pyLen > 3) {
            return (try spell(core), 1, trail)
        }
        if low == "lead", ["for", "of", "contains", "containing", "with", "no", "free", "test", "testing", "tested"].contains(pl),
           !["the", "a", "an", "us", "them", "you", "him", "her", "me", "to", "our", "your", "their", "his", "my"].contains(nl) {
            return ([core + PH + "lˈɛd"], 1, trail)
        }
        if low == "does", NUMBER_WORDS.contains(pl) || prev.pyIsDigit || ["the", "some", "many", "several", "two", "three", "few", "and"].contains(pl),
           !["not", "it", "he", "she", "this", "that", "anyone", "anybody", "everyone"].contains(nl) {
            return ([core + PH + "dˈOz"], 1, trail)
        }
        if low == "row", ["over", "about", "with", "between"].contains(nl),
           ["a", "the", "big", "huge", "blazing", "public", "family", "another", "furious"].contains(pl) {
            return ([core + PH + "ɹˈW"], 1, trail)
        }
        if low == "minute", ["a", "the"].contains(pl), MINUTE_NOUNS.contains(nl) { return ([core + PH + ADJ_FORMS["minute"]!], 1, trail) }
        return nil
    }

    func ip(_ host: String) throws -> [String] {
        var words: [String] = []
        for (k, x) in host.splitOn(".").enumerated() {
            let n = try pyInt(x)
            let w: [String] = n < 100 || n % 100 == 0 ? try cardinal(n).splitOn(" ")
                : [ONES[n / 100]] + (n % 100 < 10 ? ["oh", ONES[n % 10]] : [try cardinal(n % 100)])
            words += (k > 0 ? ["dot"] : []) + w
        }
        return words
    }

    // MARK: first-round rules
    func basic(_ c: Tok) throws -> Rule? {
        let core = c.core, trail = c.trail, prev = c.prev, prev2 = c.prev2, nxt = c.nxt, toks = c.toks, i = c.i, pauses = c.pauses
        let low = core.lower
        let dot = trail.starts(".")
        let keepDot = i + 1 >= toks.count || nxt.firstIsUpper ? trail : trail.sl(1)
        let nxtCap = nxt.firstIsUpper
        let prevCap = (prev.firstIsUpper && prev.pyIsAlpha) || rt("^\\d+(st|nd|rd|th)?$", prev)
        let nxtNum = nxt.firstIsDigit
        let prevNum = rt("^-?\\d[\\d,]*(\\.\\d+)?$", prev)

        if let m = P_EMAIL.match(core) { return ((try sayParts(m.s(1))) + ["at"] + (try domain(m.s(2))), 1, trail) }
        if core.starts("@"), rt("^@[A-Za-z0-9_]+$", core) { return (["at"] + (try sayParts(core.sl(1))), 1, trail) }
        if core.starts("#"), core.pyLen > 1 {
            let rest = core.sl(1)
            if rest.pyIsDigit { return (["number"] + (core.pyLen > 4 ? try digitWords(rest) : [rest]), 1, trail) }
            if rt("^#[A-Za-z]\\w*$", core) {
                let parts = RX.get("[A-Z]?[a-z]+|[A-Z]+(?![a-z])|\\d+").findall(rest)
                return (["hashtag"] + parts.map { known($0.lower) ? $0.lower : $0 }, 1, trail)
            }
        }
        if rt("^[A-G]#$", core) { return ([core.first1, "sharp"], 1, trail) }
        if let m = P_URL.match(core) {
            let g1 = m.g(1), g2 = m.s(2)
            let tld = try g2.rsplit1(".").req(1)
            if (g1 != nil || TLDS.contains(tld.lower)), rs("[A-Za-z]{2}", g2.splitOn(".")[0]), g1 != nil || !dot || low.count(of: ".") >= 1 {
                var host = g2
                if g1 == nil, !TLDS.contains(try host.rsplit1(".").req(1)) { return nil }
                if WORD_ABBR[low] != nil || ["e.g.", "i.e."].contains(low + ".") { return nil }
                var words: [String] = []
                if host.lower.starts("www.") {
                    words += (try spell("www")) + ["dot"]
                    host = host.sl(4)
                }
                words += try domain(host)
                for seg in (m.g(3) ?? "").splitOn("/").dropFirst() {
                    words.append("slash")
                    if rt("^[a-z]{2}[-_][a-z]{2}$", seg, true) {
                        words += (try spell(seg.sl(0, 2))) + [try SEP_WORDS.req(try seg.at(2))] + (try spell(seg.sl(3)))
                    } else if rt("^[1-9]\\d{0,3}$", seg) {
                        words.append(seg)
                    } else if !seg.isEmpty {
                        words += try sayParts(seg)
                    }
                }
                return (words, 1, trail)
            }
        }
        if let m = P_MONEY.match(core), !m.s(3).isEmpty || !m.s(4).isEmpty {
            let nscale: String? = SCALE_WORDS.contains(nxt.lower) && m.s(5).isEmpty ? nxt.lower : nil
            let words = try money(m.g(1), m.s(2), m.g(3), m.g(4), m.g(5), nscale)
            if nscale != nil { return (words, 2, Normalizer.split(c.nxtRaw).2) }
            return (words, 1, trail)
        }
        if let m = P_CENTS.match(core) { return ([m.s(1), m.s(1) == "1" ? "cent" : "cents"], 1, trail) }
        if let m = P_DEGREES.match(core), m.g(2) != nil || core.ends("°") {
            let n = m.s(1)
            let words = (n.starts("-") ? ["minus", n.sl(1)] : [n]) + [["1", "-1"].contains(n) ? "degree" : "degrees"]
            return (words + (["C": ["Celsius"], "F": ["Fahrenheit"]][m.s(2)] ?? []), 1, trail)
        }
        if let m = P_TOLLWORD.match(core) { return (try phone(["1", m.s(1), m.s(2)], pauses), 1, trail) }
        if let m = P_PHONE.match(core) {
            let g = (1..<m.groups.count).compactMap { m.g($0) }.filter { !$0.isEmpty }
            return (try phone(g.map { $0.lstrip("+") }, pauses, plus: g[0].starts("+")), 1, trail)
        }
        if rt("^\\(\\d{3}\\)$", toks[i]) || (rt("^\\d{3}$", core) && toks[i].starts("(")) {
            if let m2 = rm("^(\\d{3})-(\\d{4})$", nxt) {
                return (try phone([core, m2.s(1), m2.s(2)], pauses), 2, Normalizer.split(c.nxtRaw).2)
            }
        }
        if rt("^\\+\\d{1,3}$", core) {
            var groups = [core.sl(1)]
            var j = i + 1
            while j < toks.count, rt("^\\d{1,4}(-\\d{1,4})*$", Normalizer.split(toks[j]).1) {
                groups += Normalizer.split(toks[j]).1.splitOn("-")
                j += 1
                if !Normalizer.split(toks[j - 1]).2.isEmpty { break }
            }
            if groups.count >= 3 { return (try phone(groups, pauses, plus: true), j - i, Normalizer.split(toks[j - 1]).2) }
        }
        if let m = P_PHONE7.match(core), !prevNum { return (try phone([m.s(1), m.s(2)], pauses), 1, trail) }
        if rt("^[2-9]11$", core), core == "911" || ["dial", "call", "called", "calling"].contains(prev.lower) {
            return (try digitWords(core), 1, trail)
        }
        if P_IPV4.test(core), try core.splitOn(".").allSatisfy({ try pyInt($0) < 256 }) { return (try ip(core), 1, trail) }
        if let m = P_VERSION.match(core), m.s(2).count(of: ".") >= 2 || m.g(1) != nil {
            var words: [String] = m.g(1) != nil && !["version", "release", "v"].contains(prev.lower) ? ["version"] : []
            for (k, x) in m.s(2).splitOn(".").enumerated() {
                words += (k > 0 ? ["point"] : []) + (!(x.pyLen > 1 && x.starts("0")) ? [x] : try digitWords(x))
            }
            if let g3 = m.g(3), !g3.isEmpty { words += RX.get("[A-Za-z]+|\\d+").findall(g3) }
            return (words, 1, trail)
        }
        if let m = P_LEADING_POINT.match(core) { return (["point"] + (try digitWords(m.s(1))), 1, trail) }
        if let m = P_DECADE.match(core), m.s(1).ends("0") {
            let v = try pyInt(m.s(1))
            if m.s(1).pyLen == 2 || (1000 <= v && v <= 2090) { return (try pluralNumber(v).splitOn(" "), 1, trail) }
        }
        if let m = P_DATE_ISO.match(core) {
            let mo = try pyInt(m.s(2)), d = try pyInt(m.s(3))
            if (1...12).contains(mo), (1...31).contains(d) {
                let sep = pauses ? "," : ""
                return ([MONTHS[mo - 1], try ordinalWords(d) + sep] + (try yearWords(try pyInt(m.s(1)))), 1, trail)
            }
        }
        if let m = P_DATE_MDY.match(core) {
            let mo = try pyInt(m.s(1)), d = try pyInt(m.s(2))
            if (1...12).contains(mo), (1...31).contains(d) {
                let y = m.s(3).pyLen == 4 ? m.s(3) : (try pyInt(m.s(3)) < 50 ? "20" : "19") + m.s(3)
                let sep = pauses ? "," : ""
                return ([MONTHS[mo - 1], try ordinalWords(d) + sep] + (try yearWords(try pyInt(y))), 1, trail)
            }
        }
        if let m = P_FRACTION.match(core) {
            let n = try pyInt(m.s(1)), d = try pyInt(m.s(2))
            let fr = try Normalizer.fraction(n, d)
            let unitNext = ["of", "inch", "inches", "cup", "cups", "mile", "miles", "teaspoon", "teaspoons", "tablespoon", "tablespoons",
                            "pound", "pounds", "ounce", "ounces", "hour", "hours", "an", "a", "in", "tsp", "tbsp", "lb", "oz"].contains(nxt.lower)
            if let fr, [2, 3, 4, 8].contains(d) || unitNext || ([16, 32, 64].contains(d) && n % 2 != 0) { return (fr, 1, trail) }
            if 1 <= n, n <= 12, 13 <= d, d <= 31 { return ([MONTHS[n - 1], try ordinalWords(d)], 1, trail) }
            if [(24, 7), (9, 11), (7, 11), (50, 50), (24, 365)].contains(where: { $0 == (n, d) }) { return ([String(n), String(d)], 1, trail) }
            return nil
        }
        if rt("^\\d+$", core), P_FRACTION.test(nxt) {
            let nd = try nxt.splitOn("/").map { try pyInt($0) }
            let (n, d) = (nd[0], nd[1])
            if let fr = try Normalizer.fraction(n, d), try pyInt(core) < 1000 {
                let tail = n == 1 ? ["a", fr[1]] : fr
                return ([try cardinal(try pyInt(core)), "and"] + tail, 2, Normalizer.split(c.nxtRaw).2)
            }
        }
        if let m = P_TIME.match(core), m.g(3) != nil || m.g(4) != nil || m.s(2).starts("0") {
            if let words = try time(m.s(1), m.s(2), m.g(3), m.g(4)), !words.isEmpty { return (words, 1, trail) }
        }
        if let m = P_TIME_AMPM.match(core), try pyInt(m.s(1)) <= 12 { return ([m.s(1), letter(m.s(2)), "M"], 1, trail) }
        if ["am", "pm"].contains(core), prevNum || P_TIME.test(prev) { return ([letter(core.first1), "M"], 1, trail) }
        if let m = P_RATIO.match(core), !prev.firstIsUpper, !prevNum { return ([m.s(1), "to", m.s(2)], 1, trail) }
        if rt("^\\d{1,2}:\\d{2}[-–]\\d{1,2}:\\d{2}$", core) {
            let ab = RX.get("[-–]").split(core)
            let a = ab[0], b = ab[1]
            let pa = a.splitOn(":"), pb = b.splitOn(":")
            let wa = try time(pa[0], pa[1], nil, nil) ?? [a]
            let wb = try time(pb[0], pb[1], nil, nil) ?? [b]
            return (wa + ["to"] + wb, 1, trail)
        }
        if let m = P_RANGE.match(core) {
            let a = m.s(1), b = m.s(2)
            if a == b { return ([a, b], 1, trail) }
            return ([a, "to", b], 1, trail)
        }
        if let m = P_TIMES_X.match(core) { return (pairs(m.s(1)) + ["by"] + pairs(m.s(2)), 1, trail) }
        if let m = P_MULT.match(core) { return ([m.s(1), "times"], 1, trail) }
        if let m = UNIT_GLUED.match(core) {
            let (sing, plur) = try UNITS.req(m.s(2))
            return ([m.s(1)] + (m.s(1) == "1" ? sing : plur).splitOn(" "), 1, trail)
        }
        if P_DIGITS.test(core) { return (try digitWords(core), 1, trail) }
        if ["~", "≈"].contains(core), nxtNum { return (["about"], 1, trail) }
        if core.starts("~"), rt("^~\\d", core) { return (["about", core.sl(1)], 1, trail) }
        if [">", "<", "*", "=", "+", "&", "±", ">=", "<="].contains(core), prevNum || nxtNum || core == "&" {
            var say: [String] = [">": ["is", "greater", "than"], "<": ["is", "less", "than"], "*": ["times"], "=": ["equals"],
                                 "+": ["plus"], "&": ["and"], "±": ["plus", "or", "minus"], ">=": ["is", "at", "least"],
                                 "<=": ["is", "at", "most"]][core]!
            if [">", "<"].contains(core), ["is", "are", "was", "were"].contains(prev.lower) { say = Array(say.dropFirst()) }
            return (say, 1, trail)
        }
        if rt("^[A-Z]{1,3}&[A-Z]{1,3}$", core) {
            let ab = core.splitOn("&")
            return ((try spell(ab[0])) + ["and"] + (try spell(ab[1])), 1, trail)
        }
        if rt("^[A-Za-z]+&[A-Za-z]+$", core) {
            let ab = core.splitOn("&")
            return ([ab[0], "and", ab[1]], 1, trail)
        }
        if rs("[A-Za-z](—|--|–)[A-Za-z]", core) {
            return (RX.get("—|--|–").split(core).filter { !$0.isEmpty }, 1, trail)
        }
        if rt("^(?i:rock)['’]n['’](?i:roll)$", core) {
            return ([core.splitOn("'")[0].splitOn("’")[0], "and", "roll"], 1, trail)
        }

        if prevNum, let u = UNITS[core], !(["in", "m", "g"].contains(core) && !dot && core != "m") {
            if core == "in" { return nil }
            return ((["1", "-1"].contains(prev) ? u.0 : u.1).splitOn(" "), 1, trail)
        }
        if prevNum, low == "in", dot {
            return ([prev == "1" ? "inch" : "inches"], 1, keepDot != trail ? keepDot.sl(1) : trail)
        }
        if prevNum, ["ft", "lbs", "lb", "oz", "hrs", "hr", "mins", "min", "secs", "sec", "yrs", "yr", "tsp", "tbsp", "mi", "yds", "yd", "gal", "qt"].contains(low), dot {
            var w = try WORD_ABBR.req(low)
            if !["1", "-1"].contains(prev) {
                w = ["foot": "feet", "inch": "inches", "pound": "pounds", "ounce": "ounces", "hour": "hours", "minute": "minutes",
                     "second": "seconds", "year": "years", "teaspoon": "teaspoons", "tablespoon": "tablespoons", "mile": "miles",
                     "yard": "yards", "gallon": "gallons", "quart": "quarts"][w] ?? w
            }
            return ([w], 1, !(i + 1 >= toks.count || nxtCap) ? trail.sl(1) : trail)
        }

        if dot || low == "e.g" {
            let key = low
            if key == "e.g" { return (try WORD_ABBR.req(key).splitOn(" "), 1, dot ? trail.sl(1) : trail) }
            if key == "no", ["No", "no"].contains(core), nxtNum || nxt.starts("#") { return (["number"], 1, trail.sl(1)) }
            if ["st", "dr"].contains(key), core.firstIsUpper {
                if prevCap || prevNum, !c.prevEnd, !(nxtCap && i + 1 < toks.count && trail == ".") {
                    return ([try STREET_ABBR.req(key)], 1, trail.pyLen == 1 ? keepDot : trail.sl(1))
                }
                if key == "st", nxtCap, trail == "." { return (["Saint"], 1, "") }
                return nil
            }
            if ["jr", "sr"].contains(key), core.firstIsUpper, prevCap { return ([try STREET_ABBR.req(key)], 1, keepDot) }
            if let t = TITLE_ABBR[key], core.firstIsUpper, nxtCap || nxtNum {
                if key == "ft", !nxtCap { return nil }
                return ([t], 1, trail.sl(1))
            }
            if let s = STREET_ABBR[key], core.firstIsUpper, !["st", "dr", "jr", "sr"].contains(key), prevCap || prevNum {
                return ([s], 1, keepDot)
            }
            if let mo = MONTH_ABBR[key], core.firstIsUpper, nxtNum || prevNum { return ([MONTHS[mo - 1]], 1, keepDot) }
            if let d = DAY_ABBR[key], core.firstIsUpper { return ([d], 1, keepDot) }
            if ["vs", "approx", "apt", "dept", "est", "fig", "vol", "ch", "pp", "ca", "cf", "corp", "govt", "intl", "misc"].contains(key),
               key != "ch" || nxtNum, key != "est" || nxtNum, !["fig", "vol", "pp", "apt"].contains(key) || nxtNum || nxt.firstIsUpper {
                return (try WORD_ABBR.req(key).splitOn(" "), 1, !(i + 1 >= toks.count || nxtCap) ? trail.sl(1) : trail)
            }
        }
        let mdy = rt("^\\d{1,2}(st|nd|rd|th)?$", nxt)
        if (MONTH_ABBR[low] != nil && core.firstIsUpper && core.pyIsAlpha && nxtNum && mdy && !["mar", "jun"].contains(low)) ||
            (["mar", "jun"].contains(low) && core.firstIsUpper && mdy) {
            return ([MONTHS[try MONTH_ABBR.req(low) - 1]], 1, trail)
        }
        if low == "vs" { return (["versus"], 1, trail) }

        if ROMAN.test(core), core.pyIsUpper {
            let v = try romanValue(core)
            let pl = prev.lower
            if v != 0, REGNAL.contains(pl), prev.firstIsUpper, core.pyLen > 1 || !trail.isEmpty || nxt.isEmpty || nxt.lower == "of" {
                return (["the", try ordinalWords(v)], 1, trail)
            }
            if (v != 0 && ROMAN_CUE.contains(pl) && prev.firstIsUpper && (core.pyLen > 1 || ["V", "X"].contains(core))) ||
                (v != 0 && ROMAN_CUE.contains(pl) && core == "I" && (!trail.isEmpty || nxt.isEmpty)) {
                return ([try cardinal(v)], 1, trail)
            }
            if v != 0, core.pyLen > 1, !ROMAN_AMBIGUOUS.contains(core), prev.firstIsUpper, prev.pyIsAlpha, !prev.pyIsUpper {
                return ([try cardinal(v)], 1, trail)
            }
        }

        let plain = stripOkina(core)
        if let s = SAY_AS_CASED[core] { return ([core + PH + s], 1, trail) }
        if let s = SAY_AS[plain.lower], plain.rep("-", "").pyIsAlpha,
           !["kea", "lanai"].contains(plain.lower) || prev.lower == "mauna" || plain.firstIsUpper {
            return ([plain + PH + s], 1, trail)
        }
        let pl = prev.lower
        if let vf = VERB_FORMS[low], VERB_BEFORE.contains(pl), low != "live" || ["i", "eye"].contains(pl), low != "present" || pl == "please" {
            return ([core + PH + vf], 1, trail)
        }
        if low == "close", VERB_BEFORE.contains(pl) || c.prevEnd, OBJECTS.contains(nxt.lower) { return ([core + PH + "klˈOz"], 1, trail) }
        if low == "bow", (["a", "his", "her", "their", "final"].contains(pl) && ["take", "took", "takes", "taking", "a"].contains(prev2)) ||
            ["down", "before", "deeply", "low"].contains(nxt.lower) {
            return ([core + PH + "bˈW"], 1, trail)
        }
        if low == "wound", Set(["up", "down", "around", "round", "through", "back"]).union(OBJECTS).contains(nxt.lower),
           !["the", "a", "his", "her", "my", "your", "our", "their", "its", "this", "that", "open", "deep", "fresh", "stab", "gunshot",
             "head", "old"].contains(pl) {
            return ([core + PH + "wˈWnd"], 1, trail)
        }
        if low == "dove", SUBJECTS.contains(pl) ||
            ["into", "in", "under", "off", "for", "down", "through", "onto", "deep", "headfirst", "back"].contains(nxt.lower) {
            return ([core + PH + "dˈOv"], 1, trail)
        }
        if low == "bass", ["largemouth", "smallmouth", "striped", "sea", "rock", "peacock"].contains(pl) ||
            (pl == "a" && ["caught", "catch", "catching", "landed", "hooked"].contains(prev2)) ||
            ["fishing", "fisherman", "boat", "lure", "lures", "pond"].contains(nxt.lower) {
            return ([core + PH + "bˈæs"], 1, trail)
        }
        if isEmoji(core) { return ([], 1, trail) }
        if let said = try homograph(core, toks, i) { return ([core + PH + said], 1, trail) }
        return nil
    }

    func pairs(_ d: String) -> [String] {
        let dc = d.chars
        if d.pyLen == 4, d.sl(2) != "00", !d.starts("0") { return [d.sl(nil, 2), dc[2] != "0" ? d.sl(2) : "oh " + dc[3]] }
        return [d]
    }
}
