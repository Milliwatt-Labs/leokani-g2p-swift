// SPDX-License-Identifier: MIT
// Leokani G2P by Milliwatt Labs (milliwattlabs.com)
//
// v1.2 normaliser rules: letters and initialisms, codes, ranges, units, phone numbers, web handles, and the
// homograph table. A line-for-line port of the matching parts of leokani_g2p.py; keep the two in step.
import Foundation

extension String {
    /// str.capitalize()
    var pyCapitalize: String {
        let s = sc
        guard let f = s.first else { return "" }
        return String(f).uppercased() + String(scalars: s.dropFirst()).lowercased()
    }
}

@inline(__always) private func same(_ a: String, _ b: String) -> Bool { a.unicodeScalars.elementsEqual(b.unicodeScalars) }

/// Could an English reader say this all-letter run as a word ("BLORB" yes, "AGC" or "QRT" no)?
func pronounceable(_ w0: String) -> Bool {
    let w = w0.lower
    if !w.pyIsAscii || !w.pyIsAlpha { return false }
    if w.pyLen <= 3 { return rt("^[bcdfghjklmnpqrstvwxz]?[aeiou][bcdfgklmnprstvxz]?$", w) }
    let groups = RX.get("[aeiou]+|(?<=[^aeiou])y(?![aeiou])|[^aeiou]").findall(w)
    func vowel(_ g: String) -> Bool { g.first1.isIn("aeiou") || g == "y" }
    var merged: [String] = []
    for g in groups {
        if let l = merged.last, !vowel(g), !vowel(l) { merged[merged.count - 1] = l + g } else { merged.append(g) }
    }
    let vows = merged.filter(vowel)
    if vows.isEmpty || vows.contains(where: { $0.pyLen > 2 }) { return false }
    for (k, g) in merged.enumerated() {
        if vowel(g) { continue }
        if k == 0 {
            if !ONSETS.contains(g) { return false }
        } else if k == merged.count - 1 {
            if !CODAS.contains(g) { return false }
        } else if !(0...g.pyLen).contains(where: { j in CODAS.contains(g.sl(0, j)) && ONSETS.contains(g.sl(j)) }) || g.pyLen > 4 {
            return false
        }
    }
    return true
}

// MARK: - homograph tests (see HOMOGRAPHS in leokani_g2p.py for the test language)

private var HG_SETS: [String: Set<String>] = [:]
private let HG_LOCK = NSLock()

func hgSet(_ v: String) throws -> Set<String> {
    var out = Set<String>()
    for x in v.splitOn("|") {
        if x.starts("@") { out.formUnion(try HG_CLASSES.req(x.sl(1)).words) } else { out.insert(x) }
    }
    return out
}

func hgTest(_ t: String, _ prev: [String], _ nxt: [String], _ cap: Bool) throws -> Bool {
    if t == "cap" { return cap }
    if t == "!cap" { return !cap }
    var op = "", k = -1
    for o in ["!=", "!~", "=", "~"] {
        op = o
        k = t.find(o)
        if k > 0 { break }
    }
    let field = t.sl(0, k), vals = t.sl(k + op.pyLen)
    var ws: [String]
    if field == "P" || field == "N" {
        let seq = field == "P" ? prev : nxt
        ws = seq.filter { $0 != "^" && $0 != "$" }
        if ws.isEmpty { ws = [try seq.req(-1)] }
    } else {
        let seq = try field.at(0) == "p" ? prev : nxt
        let n = try pyInt(try field.at(1)) - 1
        ws = [n < seq.count ? try seq.req(n) : try seq.req(-1)]
    }
    if op == "~" || op == "!~" {
        let ends = vals.splitOn("|")
        let hit = ws.contains { w in w != "^" && w != "$" && ends.contains { w.ends($0) } }
        return op == "~" ? hit : !hit
    }
    HG_LOCK.lock()
    let cached = HG_SETS[vals]
    HG_LOCK.unlock()
    let s: Set<String>
    if let cached { s = cached } else {
        s = try hgSet(vals)
        HG_LOCK.lock(); HG_SETS[vals] = s; HG_LOCK.unlock()
    }
    let hit = ws.contains { s.contains($0) }
    return op == "!=" ? !hit : hit
}

extension Normalizer {
    // MARK: v1.2 helpers
    /// An initialism said as one word, stress on the last letter ("NBA"); end is a plural or possessive ("IDs", "AGC's").
    func spellWord(_ s: String, _ end: String = "") throws -> [String] {
        let names = s.chars.map { letters[$0.lower] }
        if !s.pyIsAlpha || !s.pyIsAscii || names.contains(where: { $0 == nil }) { return try spell(s) }
        let last = !end.isEmpty ? try letterPlural(s.last1, end == "s" ? "" : end).split1(PH).req(1) : names[names.count - 1]!
        return [s + end + PH + names.dropLast().map { $0!.rep(PRIMARY, SECONDARY) }.joined() + last]
    }

    /// 'Os' in "CEOs", 'C's' in "AGC's": a letter name said with a plural or possessive ending.
    func letterPlural(_ c: String, _ possessive: String = "") -> String {
        let ph = letters[c.lower] ?? ""
        let l = c.lower
        return c.upper + (possessive.isEmpty ? "s" : possessive) + PH + ph +
            (LETTER_PLURAL_ES.contains(l) ? "ᵻz" : LETTER_PLURAL_S.contains(l) ? "s" : "z")
    }

    /// An all-caps run said letter by letter: the lexicon spells it, or it doesn't know it and English can't say it
    /// as a word.
    func initialism(_ w: String) -> Bool {
        if ACRONYM_WORDS.contains(w) || SAY_AS_CASED[w] != nil || ROMAN.test(w) || !(w.pyIsAscii && w.pyIsAlpha) { return false }
        if cased(w) { return false }
        if known(w.lower) { return spelled(w.lower) && !reading(w.lower).isEmpty }
        return !pronounceable(w)
    }

    func single(_ t: String) -> Bool {
        let c = Normalizer.split(t).1
        return c.pyLen == 1 && c.pyIsAlpha && c.pyIsUpper && c.pyIsAscii
    }

    /// The words around token i are written in capitals as ordinary words ("PLEASE READ THE MANUAL").
    func shouted(_ toks: [String], _ i: Int) -> Bool {
        var n = 0
        for j in [i - 2, i - 1, i + 1, i + 2] where 0 <= j && j < toks.count {
            let c = Normalizer.split(toks[j]).1
            if c.pyLen >= 3, c.pyIsUpper, c.rep("'", "").rep("’", "").pyIsAlpha, known(c.lower), !initialism(c) { n += 1 }
        }
        return n >= 2
    }

    func spelledForm(_ f: String, _ w: String) -> Bool {
        func bare(_ x: String) -> String { bareStress(x).rep(" ", "") }
        return same(bare(f), w.chars.map { bare(letters[$0] ?? "?") }.joined())
    }

    // MARK: v1.2 letter rules, ahead of every other rule
    func lettersFirst(_ c: Tok) throws -> Rule? {
        let core = c.core, trail = c.trail, prev = c.prev, nxt = c.nxt, nxtRaw = c.nxtRaw, toks = c.toks, i = c.i
        let low = core.lower, pl = prev.lower, nl = nxt.lower
        // spaced single letters: "A G C"; a lone "A" or "I" before a word stays the article or the pronoun
        if core == "A" || core == "I" {
            let afterLetter = i > 0 && single(toks[i - 1]) && !["A", "I"].contains(Normalizer.split(toks[i - 1]).1)
                && !".!?;:".has(toks[i - 1].last1)
            let beforeLetter = trail.isEmpty && i + 1 < toks.count && single(nxtRaw)
            if afterLetter || beforeLetter
                || (core == "A" && (["letter", "letters", "an"].contains(pl) || (["and", "or"].contains(nl) && trail.isEmpty)
                    || (",;".has(trail.first1) && single(nxtRaw))))
                || (["and", "or"].contains(pl) && i > 1 && single(toks[i - 2])) {
                return ([letter(core)], 1, trail)
            }
        }
        // plural and possessive initialisms: "CEOs", "PDFs", "AGC's"
        if let m = rm("^([A-Z]{2,6})(s|'s|’s)$", core), SHORTHAND_CASED[m.s(1)] == nil, initialism(m.s(1)),
           SHORTHAND_CASED[core] == nil, core != "IDs" {
            return (try spellWord(m.s(1), m.s(2)), 1, trail)
        }
        // dotted capitals: "A.G.C.", "N.Y.C.", "A.I."
        if rt("^(?:[A-Z]\\.){1,}[A-Z]$", core), trail.starts("."), core.pyLen >= 3 {
            let keep = i + 1 >= toks.count || (nxt.firstIsUpper && nxt != "I") ? trail : trail.sl(1)
            let bare = core.rep(".", "")
            if ACRONYM_WORDS.contains(bare) { return ([bare], 1, keep) }
            return (try spellWord(bare), 1, keep)
        }
        // a middle initial: "George W. Bush", "Ulysses S. Grant" (not a direction)
        func initial(_ t: String) -> Bool { rt("^[A-Z]\\.$", t) }
        if core.pyLen == 1, core.pyIsUpper, trail == ".", nxt.firstIsUpper, !SENTENCE_START.contains(nl),
           initial(nxtRaw) || (i != 0 && initial(toks[i - 1]) && nxt.pyIsAlpha)
            || (prev.firstIsUpper && prev.pyIsAlpha && !prev.pyIsUpper && nxt.pyLen > 1 && nxt.pyIsAlpha
                && !".!?:;,".has(toks[i - 1].last1)),
           !toks[min(i + 1, toks.count)..<min(i + 4, toks.count)].contains(where: {
               STREET_WORDS.contains(Normalizer.split($0).1.lower.rstrip("."))
           }) {
            return ([letter(core)], 1, trail.sl(1))
        }
        // a letter before a word: "p-value", "t-test", "x-axis"; a word before a letter: "Type-C", "Plan-B"
        if let m = rm("^([a-zA-Z])-(value|values|test|tests|axis|score|scores|statistic|coordinate|intercept)$", core) {
            return ([letter(m.s(1)), m.s(2)], 1, trail)
        }
        if let m = rm("^([A-Za-z]{2,})-([A-Z])$", core), m.s(1).pyIsAlpha {
            return ([m.s(1), letter(m.s(2))], 1, trail)
        }
        // a letter and a model number: "F-150", "B-52", "F-16"
        if let m = rm("^([A-Z]{1,2})-(\\d{2,3})$", core), core.sl(0, 2) != "I-" {
            let d = m.s(2), dc = d.chars
            let num: [String]
            if d.pyLen == 2 || (dc[1] == "0" && dc[2] == "0") {
                num = try cardinal(try pyInt(d)).splitOn(" ")
            } else {
                num = [try ONES.req(try pyInt(dc[0]))] +
                    (dc[1] == "0" ? ["oh", try ONES.req(try pyInt(dc[2]))] : try cardinal(try pyInt(d.sl(1))).splitOn(" "))
            }
            return (try spell(m.s(1)) + num, 1, trail)
        }
        // mixed-case initialisms: "DoD", "DoE", "MoU"
        if rt("^[A-Z]o[A-Z]s?$", core), SAY_AS_CASED[core] == nil {
            return (try spellWord(core.sl(0, 3), core.sl(3)), 1, trail)
        }
        // a resolution: "1080p", "720p"
        if let m = rm("^(\\d{3,4})([pi])$", core) {
            let d = m.s(1)
            let w = d.pyLen == 4 ? try pairWords(try pyInt(d))
                : [try ONES.req(try pyInt(d.first1))] + (try cardinal(try pyInt(d.sl(1))).splitOn(" "))
            return (w + [letter(m.s(2))], 1, trail)
        }
        // a possessive of a capitalised word: "NATO's"
        if let m = rm("^([A-Z]{4,})(['’]s)$", core), !initialism(m.s(1)), !reading(m.s(1).lower).isEmpty {
            let ph = reading(m.s(1).lower)[0]
            let e = ph.last1
            let end = SIBILANT_END.contains(e) ? "ᵻz" : VOICELESS_END.contains(e) ? "s" : "z"
            return ([core + PH + ph + end], 1, trail)
        }
        // a common word shouted in capitals keeps its word reading ("I CAN'T BELIEVE IT"), not its letters
        if core.pyLen >= 2, core.pyIsUpper, core.rep("'", "").rep("’", "").pyIsAlpha, known(low),
           !ACRONYM_WORDS.contains(core), SAY_AS_CASED[core] == nil, SHORTHAND_CASED[core] == nil, ZONES[core] == nil,
           !ROMAN.test(core), common(low) || !cased(core), shouted(toks, i),
           reading(low).contains(where: { !spelledForm($0, low) }) {
            return ([i != 0 && !".!?".has(toks[i - 1].last1) ? low : low.pyCapitalize], 1, trail)
        }
        return nil
    }

    // MARK: v1.2 codes, ranges, units, phones, web
    func more3(_ c: Tok) throws -> Rule? {
        let core = c.core, trail = c.trail, prev = c.prev, prev2 = c.prev2, nxt = c.nxt, nxtRaw = c.nxtRaw
        let toks = c.toks, i = c.i, pauses = c.pauses
        let low = core.lower, pl = prev.lower, nl = nxt.lower
        func isNum(_ x: String) -> Bool { rt("^-?\\d[\\d,]*(\\.\\d+)?$", x) }
        func one(_ n: String) -> Bool { n == "1" || n == "-1" }
        // respelled capitals: "IEEE", "WWII", "PhD"
        if let s = CASED_SAY[core] { return (sub(s, pauses), 1, trail) }
        if core == "ID" { return ([core + PH + "ˌIdˈi"], 1, trail) }
        // year ranges: "1990–95", "2019-2020 season"
        if let m = rm("^(1[1-9]\\d\\d|20\\d\\d)[–-](\\d\\d|1[1-9]\\d\\d|20\\d\\d)$", core) {
            let a = try pyInt(m.s(1)), b = m.s(2)
            if !core.ends("00") || (rt("^(1[1-9]\\d\\d|20\\d\\d)[–-](\\d\\d|\\d{4})$", core) && a % 100 != 0) {
                let bc = b.chars
                let bw = b.pyLen == 4 ? try yearWords(try pyInt(b))
                    : (bc[0] == "0" ? ["oh", try ONES.req(try pyInt(bc[1]))] : try cardinal(try pyInt(b)).splitOn(" "))
                let bi = try pyInt(b)
                if (b.pyLen == 4 && bi <= a) || (b.pyLen == 2 && bi <= a % 100) {
                    // not a range: a code
                } else {
                    let joint: [String] = ["season", "seasons", "school", "academic", "fiscal", "tax", "budget",
                                           "financial"].contains(nl) ? [] : ["to"]
                    return (try yearWords(a) + joint + bw, 1, trail)
                }
            }
        }
        // a range in percent: "20–30%"
        if let m = rm("^(\\d[\\d,]*(?:\\.\\d+)?)[–-](\\d[\\d,]*(?:\\.\\d+)?)%$", core) {
            return ([m.s(1), "to", m.s(2), "percent"], 1, trail)
        }
        // day ranges after a month: "Jan 3–7", "May 12-19"
        if let m = rm("^(\\d{1,2})[–-](\\d{1,2})$", core),
           MONTHS.contains(prev) || (MONTH_ABBR[pl.rstrip(".")] != nil && prev.firstIsUpper) {
            let a = try pyInt(m.s(1)), b = try pyInt(m.s(2))
            if 1 <= a && a < b && b <= 31 { return ([try ordinalWords(a), "to", try ordinalWords(b)], 1, trail) }
        }
        // fraction ranges: "1/2-1 cup", "1–1/2 tsp"
        if let m = rm("^(\\d{1,2}(?:/\\d{1,2})?)[–-](\\d{1,2}(?:/\\d{1,2})?)$", core), core.has("/") {
            var out: [String]? = []
            for (k, part) in [m.s(1), m.s(2)].enumerated() {
                let to: [String] = k > 0 ? ["to"] : []
                if part.has("/") {
                    let xs = part.splitOn("/")
                    guard let fr = try Normalizer.fraction(try pyInt(xs[0]), try pyInt(xs[1])), !fr.isEmpty else { out = nil; break }
                    out! += to + fr
                } else {
                    out! += to + [part]
                }
            }
            if let o = out, !o.isEmpty { return (o, 1, trail) }
        }
        // aircraft: "Boeing 737-800", "Airbus A320"
        if let m = rm("^([1-9])(\\d\\d)(?:-(\\d{1,3}))?$", core),
           ["boeing", "airbus", "embraer", "bombardier", "douglas", "md", "dc"].contains(pl) {
            var w = [try ONES.req(try pyInt(m.s(1)))] + (try cardinal(try pyInt(m.s(2))).splitOn(" "))
            if let g3 = m.g(3), !g3.isEmpty { w += try cardinal(try pyInt(g3)).splitOn(" ") }
            return (w, 1, trail)
        }
        // years with an era: "A.D. 1250", "500 BC"
        let eras = ["A.D", "AD", "B.C", "BC", "CE", "BCE", "B.C.E"]
        if rt("^\\d{3,4}$", core), eras.contains(prev.rstrip(".")) || eras.contains(nxt.rstrip(".")), !core.ends("00") {
            return (try yearWords(try pyInt(core)), 1, trail)
        }
        // a month before a day range: "Jan 3–7"
        if let mo = MONTH_ABBR[low.rstrip(".")], core.firstIsUpper, core.pyIsAlpha, rt("^\\d{1,2}[–-]\\d{1,2}$", nxt) {
            return ([try MONTHS.req(mo - 1)], 1, trail.starts(".") ? trail.sl(1) : trail)
        }
        // a port: "port 443", "port 8080"
        if rt("^\\d{2,5}$", core), ["port", "ports"].contains(pl), !["the", "a"].contains(prev2) {
            let cc = core.chars
            let w: [String]
            if core.pyLen == 4, core.sl(1) != "000", try pyInt(core) < 2100 {
                w = try pairWords(try pyInt(core))
            } else if core.pyLen == 4, cc[2] != "0", core.sl(1) != "000" {
                w = [core.sl(0, 2), core.sl(2)]
            } else if core.pyLen == 3, cc[1] != "0" {
                w = [cc[0], core.sl(1)]
            } else {
                w = [core]
            }
            return (w, 1, trail)
        }
        // a weekday after a dash: "Tue–Thu", "Mon - Fri"
        if let day = DAY_ABBR[low], core.firstIsUpper, core.pyIsAlpha,
           ["–", "-", "—", "through", "to"].contains(prev) || ["thru", "until", "till"].contains(pl),
           !(["through", "to"].contains(prev) && nxt.firstIsUpper && nxt.pyIsAlpha && DAY_ABBR[nl] == nil &&
             !DAY_ABBR.values.contains(nxt) && MONTH_ABBR[nl] == nil) {               // "I talked to Thu Crosson"
            return ([day], 1, trail.starts(".") ? trail.sl(1) : trail)
        }
        // phone numbers: "312 555 0199", "ext 12", "988", ZIP+4
        if rt("^\\d{3}$", core), rt("^\\d{3}$", nxt), i + 2 < toks.count, !toks[i].starts("("),
           !(i != 0 && rt("^\\+\\d{1,3}$", toks[i - 1])), rt("^\\d{4}$", Normalizer.split(toks[i + 2]).1),
           Normalizer.split(nxtRaw).2.isEmpty {
            let z = Normalizer.split(toks[i + 2])
            return (try phone([core, nxt, z.1], pauses), 3, z.2)
        }
        if ["ext", "extension", "x"].contains(low), trail.isEmpty, rt("^\\d{1,5}$", nxt), low != "x" || rs("\\d", prev), i != 0 {
            let z = Normalizer.split(nxtRaw)
            return (["extension"] + (z.1.pyLen > 2 ? try digitWords(z.1) : [z.1]), 2, z.2)
        }
        if core == "988", ["call", "text", "dial", "or"].contains(pl) || nxt.isEmpty { return (try digitWords(core), 1, trail) }
        if rt("^\\d{5}-\\d{4}$", core) { return (try digitWords(core.rep("-", "")), 1, trail) }
        if rt("^\\d{4}$", core), pl == "in", ["ends", "ending"].contains(prev2) {
            let v = try pyInt(core)
            if !(1100 <= v && v <= 2099) || toks[max(0, i - 6)..<i].contains(where: {
                let w = Normalizer.split($0).1.lower
                return CODE_CUE.contains(w) || w == "card" || w == "phone"
            }) {
                return (try digitWords(core), 1, trail)
            }
        }
        // codes after a cue word: "tracking number 9400111899", "code 482913", "Invoice 2024-0915", "SN 555123"
        let cue = toks[max(0, i - 3)..<i].map { Normalizer.split($0).1.lower.rstrip(":#") }
        if (rt("^#?\\d{4,}([-]\\d{2,})*$", core) && !isNum(core.rep("-", "x")) && core.has("-")) || rt("^\\d{5,}$", core) {
            if Array(cue.suffix(3)) == ["the", "code", "is"] {
                // "The code is 351576." reads the number
            } else if cue.suffix(2).contains(where: { CODE_CUE.contains($0) }) ||
                        (Array(cue.suffix(1)) == ["is"] && cue.contains(where: { CODE_CUE.contains($0) })) {
                return (try digitWords(RX.get("\\D").sub(core) { _ in "" }), 1, trail)
            }
        }
        if rt("^\\d{4}-\\d{3,}$", core), cue.suffix(2).contains(where: { CODE_CUE.contains($0) }) {
            return (try digitWords(core.rep("-", "")), 1, trail)
        }
        // units: "100 m²", "500 MB/s", "10 sq ft", "2 in long", "180 °C", "250 g of flour"
        if let m = rm("^(\\d[\\d,]*(?:\\.\\d+)?)?(km|m|cm|mm|ft|in|mi|yd)([²³])$", core), m.g(1) != nil || isNum(prev) {
            let n = m.g(1) ?? prev
            let name = UNITS[m.s(2)] ?? ("inch", "inches")
            let words = (m.s(3) == "²" ? "square " : "cubic ") + (one(n) ? name.0 : name.1)
            return ((m.g(1) != nil ? [n] : []) + words.splitOn(" "), 1, trail)
        }
        if let m = rm("^(\\d[\\d,]*(?:\\.\\d+)?)?([KMGT]B|[kMG]b|km|m|ft|mi)/(s|sec|h|hr|min)$", core), m.g(1) != nil || isNum(prev) {
            let n = m.g(1) ?? prev, u = m.s(2)
            let bits: [String: (String, String)] = ["Mb": ("megabit", "megabits"), "Gb": ("gigabit", "gigabits"),
                                                    "kb": ("kilobit", "kilobits")]
            guard let name = UNITS[u] ?? bits[u] else { throw G2PError("key") }
            let per = try ["s": "second", "sec": "second", "h": "hour", "hr": "hour", "min": "minute"].req(m.s(3))
            return ((m.g(1) != nil ? [n] : []) + (one(n) ? name.0 : name.1).splitOn(" ") + ["per", per], 1, trail)
        }
        if ["sq", "sq.", "cu"].contains(low), isNum(prev), UNITS[nxt] != nil || ["in", "ft"].contains(nl) {
            let z = Normalizer.split(nxtRaw)
            let u = UNITS[z.1] != nil ? z.1 : z.1.lower
            let name = UNITS[u] ?? ("inch", "inches")
            return ([low.starts("sq") ? "square" : "cubic"] + (one(prev) ? name.0 : name.1).splitOn(" "), 2,
                    z.2 != "." ? z.2.lstrip(".") : z.2)
        }
        if core == "in", isNum(prev), trail.isEmpty,
           ["long", "wide", "tall", "deep", "thick", "high", "across", "diameter", "square"].contains(nl) {
            return ([prev == "1" ? "inch" : "inches"], 1, trail)
        }
        if ["°C", "°F", "°"].contains(where: { same($0, core) }), isNum(prev) {
            return ((one(prev) ? ["degree"] : ["degrees"]) + (core == "°C" ? ["Celsius"] : core == "°F" ? ["Fahrenheit"] : []), 1, trail)
        }
        if core == "g", isNum(prev), ["of", ""].contains(nl) || !trail.isEmpty {
            let x = try UNITS.req("g")
            return ((one(prev) ? x.0 : x.1).splitOn(" "), 1, trail)
        }
        // Roman numerals: a list item "i." at the start of a line, "Grand Theft Auto V"
        if i == 0, trail == ".", ROMAN.test(core.upper), core.pyIsLower || (core.pyLen > 1 && core.pyIsUpper), nxt.firstIsUpper {
            return ([try cardinal(try romanValue(core.upper)).pyCapitalize], 1, trail)
        }
        if core == "V", prev.firstIsUpper, prev.pyIsAlpha, !prev.pyIsUpper, !REGNAL.contains(pl), !LETTER_CUE.contains(pl), i > 1,
           !".!?:;".has(toks[i - 1].last1), nxt.isEmpty || nxt.firstIsLower {
            return (["five"], 1, trail)
        }
        // web: "https" said as letters, "@bakes.by.bella", "@NYTimes"
        if ["http", "https"].contains(low), core.pyIsLower { return (try spell(low), 1, trail) }
        if rt("^@[A-Za-z0-9_]+(\\.[A-Za-z0-9_]+)+$", core) { return (["at"] + (try sayParts(core.sl(1))), 1, trail) }
        if rt("^@[A-Za-z0-9_]+$", core), rs("[a-z]", core), rs("[A-Z]{2}[a-z]", core) {
            var words = ["at"]
            for part in RX.get("[A-Z]+(?=[A-Z][a-z])|[A-Z]?[a-z]+|[A-Z]+|\\d+|_").findall(core.sl(1)) {
                if part == "_" { words += ["underscore"] }
                else if !part.pyIsUpper { words += try sayRun(part) }
                else if initialism(part) || part.pyLen <= 3 { words += try spell(part) }
                else { words += [part] }
            }
            return (words, 1, trail)
        }
        return nil
    }

    /// Last: an all-caps word the lexicon doesn't have is spelled unless English could say it as a word.
    func capitals(_ c: Tok) throws -> Rule? {
        let core = c.core
        if core.pyLen >= 2, core.pyIsUpper, core.pyIsAlpha, core.pyIsAscii, !known(core.lower), !cased(core), initialism(core) {
            return (try spellWord(core), 1, c.trail)
        }
        return nil
    }

    // MARK: homographs (v1.2): HOMOGRAPHS, first matching rule wins
    static func ctxWord(_ t: String) -> String {
        let s = t.sc
        var a = 0, b = s.count
        let open = Set(OPEN.unicodeScalars), close = Set(CLOSE.unicodeScalars)
        while a < b, open.contains(s[a]) { a += 1 }
        while b > a, close.contains(s[b - 1]) { b -= 1 }
        return String(scalars: s[a..<b]).lower.rep("’", "'")
    }

    /// The phonemes of the sense a homograph's context asks for, or nil to leave it to the context model.
    func homograph(_ core: String, _ toks: [String], _ i: Int) throws -> String? {
        guard let rules = HOMOGRAPHS[core.lower], core.pyIsAlpha else { return nil }
        func stop(_ t: String) -> Bool { HG_STOP.contains(t.last1) }
        var prev: [String] = []                              // p1, p2, p3 within the clause; "^" before its start
        var j = i - 1
        while j > i - 4 {
            if j < 0 || stop(toks[j]) { prev.append("^"); break }
            prev.append(Normalizer.ctxWord(toks[j]))
            j -= 1
        }
        var nxt: [String] = []                               // n1, n2, n3 within the clause; "$" after its end
        if !stop(toks[i]) {
            for j in (i + 1)..<(i + 4) {
                if j >= toks.count { nxt.append("$"); break }
                nxt.append(Normalizer.ctxWord(toks[j]))
                if stop(toks[j]) { break }
            }
        }
        if nxt.isEmpty || (nxt.count < 3 && nxt.last != "$") { nxt.append("$") }
        if prev.last != "^" && prev.count < 3 { prev.append("^") }
        let cap = core.firstIsUpper && prev[0] != "^"
        for (said, tests) in rules where try tests.allSatisfy({ try hgTest($0, prev, nxt, cap) }) {
            return said.isEmpty ? nil : said
        }
        return nil
    }
}
