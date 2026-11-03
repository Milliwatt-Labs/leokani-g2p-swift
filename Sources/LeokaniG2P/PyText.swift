// SPDX-License-Identifier: MIT
// Leokani G2P by Milliwatt Labs (milliwattlabs.com)
//
// Python str semantics on Swift strings. The reference runtime (leokani_g2p.py) indexes, slices and classifies by
// Unicode code point; Swift's String works in grapheme clusters and compares by canonical equivalence. Everything in
// this port that must agree with the reference goes through these helpers, which work on unicode scalars.
import Foundation

struct G2PError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String = "rule does not apply") { description = d }
}

extension Unicode.Scalar {
    var pyIsAlpha: Bool {
        switch properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }
    /// str.isdigit(): decimal digits and digit-valued characters (², ③)
    var pyIsDigit: Bool {
        guard let t = properties.numericType else { return false }
        return t == .decimal || t == .digit
    }
    var pyIsDecimal: Bool { properties.numericType == .decimal }
    var pyIsNumeric: Bool { properties.numericType != nil }
    var pyIsAlnum: Bool { pyIsAlpha || pyIsNumeric }
    var pyIsUpper: Bool { properties.isUppercase }
    var pyIsLower: Bool { properties.isLowercase }
    var pyIsCased: Bool { properties.isUppercase || properties.isLowercase || properties.generalCategory == .titlecaseLetter }
    /// str.isspace()
    var pyIsSpace: Bool {
        switch value {
        case 0x09...0x0D, 0x1C...0x1F, 0x20, 0x85, 0xA0: return true
        default:
            let c = properties.generalCategory
            return c == .spaceSeparator || c == .lineSeparator || c == .paragraphSeparator
        }
    }
    var isMark: Bool {
        let c = properties.generalCategory
        return c == .nonspacingMark || c == .spacingMark || c == .enclosingMark
    }
}

extension String {
    @inline(__always) var sc: [Unicode.Scalar] { Array(unicodeScalars) }
    var pyLen: Int { unicodeScalars.count }

    init(scalars: some Sequence<Unicode.Scalar>) {
        var u = String.UnicodeScalarView()
        u.append(contentsOf: scalars)
        self = String(u)
    }

    /// s[a:b] with Python's negative and clamped indices (code points)
    func sl(_ a: Int? = nil, _ b: Int? = nil) -> String {
        let s = sc
        let n = s.count
        func fix(_ i: Int?, _ dflt: Int) -> Int {
            guard var i else { return dflt }
            if i < 0 { i += n }
            return Swift.min(Swift.max(i, 0), n)
        }
        let lo = fix(a, 0), hi = fix(b, n)
        return lo < hi ? String(scalars: s[lo..<hi]) : ""
    }
    /// s[i] for a valid index (throws on IndexError)
    func at(_ i: Int) throws -> String {
        let s = sc
        let j = i < 0 ? i + s.count : i
        guard j >= 0, j < s.count else { throw G2PError("index") }
        return String(s[j])
    }
    var first1: String { sl(0, 1) }
    var last1: String { sl(-1) }

    var pyIsAlpha: Bool { !isEmpty && unicodeScalars.allSatisfy { $0.pyIsAlpha } }
    var pyIsDigit: Bool { !isEmpty && unicodeScalars.allSatisfy { $0.pyIsDigit } }
    var pyIsAlnum: Bool { !isEmpty && unicodeScalars.allSatisfy { $0.pyIsAlnum } }
    var pyIsAscii: Bool { unicodeScalars.allSatisfy { $0.isASCII } }
    var pyIsUpper: Bool {
        var cased = false
        for u in unicodeScalars {
            if u.pyIsLower || u.properties.generalCategory == .titlecaseLetter { return false }
            if u.pyIsUpper { cased = true }
        }
        return cased
    }
    var pyIsLower: Bool {
        var cased = false
        for u in unicodeScalars {
            if u.pyIsUpper || u.properties.generalCategory == .titlecaseLetter { return false }
            if u.pyIsLower { cased = true }
        }
        return cased
    }
    var lower: String { lowercased() }
    var upper: String { uppercased() }
    var anyDigit: Bool { unicodeScalars.contains { $0.pyIsDigit } }
    var anyAlpha: Bool { unicodeScalars.contains { $0.pyIsAlpha } }
    /// "".isupper() style tests on the first code point: s[:1].isupper()
    var firstIsUpper: Bool { first1.pyIsUpper }
    var firstIsLower: Bool { first1.pyIsLower }
    var firstIsDigit: Bool { first1.pyIsDigit }

    func has(_ x: String) -> Bool { x.isEmpty || range(of: x, options: .literal) != nil }
    func starts(_ x: String) -> Bool { unicodeScalars.starts(with: x.unicodeScalars) }
    func ends(_ x: String) -> Bool {
        let a = sc, b = x.sc
        return b.count <= a.count && Array(a[(a.count - b.count)...]) == b
    }
    func rep(_ a: String, _ b: String) -> String { replacingOccurrences(of: a, with: b, options: .literal) }
    func count(of x: String) -> Int {
        guard !x.isEmpty else { return pyLen + 1 }
        return components(separatedBy: x).count - 1
    }
    /// str.find / str.rfind on code points
    func find(_ x: String) -> Int {
        let a = sc, b = x.sc
        guard b.count <= a.count else { return -1 }
        for i in 0...(a.count - b.count) where Array(a[i..<(i + b.count)]) == b { return i }
        return -1
    }
    func rfind(_ x: String) -> Int {
        let a = sc, b = x.sc
        guard b.count <= a.count else { return -1 }
        for i in stride(from: a.count - b.count, through: 0, by: -1) where Array(a[i..<(i + b.count)]) == b { return i }
        return -1
    }

    func strip(_ chars: String) -> String { lstrip(chars).rstrip(chars) }
    func lstrip(_ chars: String) -> String {
        let set = Set(chars.unicodeScalars)
        return String(scalars: unicodeScalars.drop { set.contains($0) })
    }
    func rstrip(_ chars: String) -> String {
        let set = Set(chars.unicodeScalars)
        var s = sc
        while let l = s.last, set.contains(l) { s.removeLast() }
        return String(scalars: s)
    }
    /// str.strip() with no argument
    var pyStrip: String {
        var s = sc
        while let l = s.last, l.pyIsSpace { s.removeLast() }
        let i = s.firstIndex { !$0.pyIsSpace } ?? s.count
        return String(scalars: s[i...])
    }
    func rstripSpace() -> String {
        var s = sc
        while let l = s.last, l.pyIsSpace { s.removeLast() }
        return String(scalars: s)
    }
    /// str.split() (whitespace runs, no empties)
    var words: [String] {
        var out: [String] = []
        var cur = String.UnicodeScalarView()
        for u in unicodeScalars {
            if u.pyIsSpace {
                if !cur.isEmpty { out.append(String(cur)); cur = String.UnicodeScalarView() }
            } else { cur.append(u) }
        }
        if !cur.isEmpty { out.append(String(cur)) }
        return out
    }
    /// str.split(sep) (keeps empties)
    func splitOn(_ sep: String) -> [String] { components(separatedBy: sep) }
    /// str.split(sep, 1)
    func split1(_ sep: String) -> [String] {
        guard let r = range(of: sep, options: .literal) else { return [self] }
        return [String(self[..<r.lowerBound]), String(self[r.upperBound...])]
    }
    /// str.partition(sep)
    func partition(_ sep: String) -> (String, String, String) {
        guard let r = range(of: sep, options: .literal) else { return (self, "", "") }
        return (String(self[..<r.lowerBound]), sep, String(self[r.upperBound...]))
    }
    /// str.rpartition(sep)
    func rpartition(_ sep: String) -> (String, String, String) {
        guard let r = range(of: sep, options: [.literal, .backwards]) else { return ("", "", self) }
        return (String(self[..<r.lowerBound]), sep, String(self[r.upperBound...]))
    }
    /// str.rsplit(sep, 1)
    func rsplit1(_ sep: String) -> [String] {
        guard let r = range(of: sep, options: [.literal, .backwards]) else { return [self] }
        return [String(self[..<r.lowerBound]), String(self[r.upperBound...])]
    }
    /// each code point as a one-scalar string
    var chars: [String] { unicodeScalars.map { String($0) } }
    func isIn(_ chars: String) -> Bool { !isEmpty && chars.has(self) }
}

/// int(s) as Python reads a decimal string (Unicode digits, a sign, surrounding spaces); throws on ValueError
func pyInt(_ s: String) throws -> Int {
    let t = s.pyStrip
    var u = t.sc
    var neg = false
    if let f = u.first, f == "-" || f == "+" { neg = f == "-"; u.removeFirst() }
    guard !u.isEmpty else { throw G2PError("int") }
    var n = 0
    var lastUnderscore = true
    for c in u {
        if c == "_" { if lastUnderscore { throw G2PError("int") }; lastUnderscore = true; continue }
        guard c.pyIsDecimal, let v = c.properties.numericValue else { throw G2PError("int") }
        let (m, o1) = n.multipliedReportingOverflow(by: 10)
        let (a, o2) = m.addingReportingOverflow(Int(v))
        if o1 || o2 { throw G2PError("int overflow") }
        n = a
        lastUnderscore = false
    }
    if lastUnderscore { throw G2PError("int") }
    return neg ? -n : n
}

extension Dictionary {
    /// d[k] that throws KeyError
    func req(_ k: Key) throws -> Value {
        guard let v = self[k] else { throw G2PError("key") }
        return v
    }
}

extension Array {
    func req(_ i: Int) throws -> Element {
        let j = i < 0 ? i + count : i
        guard j >= 0, j < count else { throw G2PError("index") }
        return self[j]
    }
}

// MARK: - regular expressions with Python re's match/search/findall/sub/split

struct Match {
    let s: String
    let groups: [String?]       // 0 = the whole match
    let range: Range<String.Index>
    func g(_ i: Int) -> String? { groups[i] }
    /// m.group(i) where it took part
    func s(_ i: Int) -> String { groups[i] ?? "" }
}

final class Re {
    let re: NSRegularExpression
    init(_ pattern: String, _ ci: Bool = false) {
        // Python's \d, \w and \s are Unicode classes, as ICU's are by default
        re = try! NSRegularExpression(pattern: pattern, options: ci ? [.caseInsensitive] : [])
    }
    private func make(_ s: String, _ r: NSTextCheckingResult) -> Match {
        var gs: [String?] = []
        for i in 0..<r.numberOfRanges {
            let nr = r.range(at: i)
            if nr.location == NSNotFound { gs.append(nil) } else { gs.append(String(s[Range(nr, in: s)!])) }
        }
        return Match(s: s, groups: gs, range: Range(r.range, in: s)!)
    }
    /// re.match: anchored at the start
    func match(_ s: String) -> Match? {
        let ns = s as NSString
        guard let r = re.firstMatch(in: s, options: [.anchored], range: NSRange(location: 0, length: ns.length)) else { return nil }
        return make(s, r)
    }
    func test(_ s: String) -> Bool { match(s) != nil }
    func search(_ s: String) -> Match? {
        let ns = s as NSString
        guard let r = re.firstMatch(in: s, options: [], range: NSRange(location: 0, length: ns.length)) else { return nil }
        return make(s, r)
    }
    func finditer(_ s: String) -> [Match] {
        let ns = s as NSString
        return re.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length)).map { make(s, $0) }
    }
    func findall(_ s: String) -> [String] { finditer(s).map { $0.s(0) } }
    func sub(_ s: String, _ f: (Match) -> String) -> String {
        var out = ""
        var last = s.startIndex
        for m in finditer(s) {
            out += s[last..<m.range.lowerBound]
            out += f(m)
            last = m.range.upperBound
        }
        out += s[last...]
        return out
    }
    /// re.split, with capture groups kept between the parts
    func split(_ s: String) -> [String] {
        var out: [String] = []
        var last = s.startIndex
        for m in finditer(s) {
            out.append(String(s[last..<m.range.lowerBound]))
            for g in m.groups.dropFirst() { out.append(g ?? "") }
            last = m.range.upperBound
        }
        out.append(String(s[last...]))
        return out
    }
}

/// a regex cache for inline patterns (re.match(r"...", x) in the reference)
enum RX {
    private static var cache: [String: Re] = [:]
    private static let lock = NSLock()
    static func get(_ p: String, _ ci: Bool = false) -> Re {
        let key = (ci ? "i:" : "c:") + p
        lock.lock(); defer { lock.unlock() }
        if let r = cache[key] { return r }
        let r = Re(p, ci)
        cache[key] = r
        return r
    }
}

@inline(__always) func rm(_ p: String, _ s: String, _ ci: Bool = false) -> Match? { RX.get(p, ci).match(s) }
@inline(__always) func rt(_ p: String, _ s: String, _ ci: Bool = false) -> Bool { RX.get(p, ci).match(s) != nil }
@inline(__always) func rs(_ p: String, _ s: String) -> Bool { RX.get(p).search(s) != nil }
