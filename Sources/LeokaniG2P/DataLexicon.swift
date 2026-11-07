// SPDX-License-Identifier: MIT
// Leokani G2P by Milliwatt Labs (milliwattlabs.com)
//
// The 1.3 lexicon files: leokani-g2p.data (the tables + the common words) and leokani-g2p-words.data (the other
// words, read on the first look-up that needs them). Layout, little-endian:
//   "LKG2P13\x01", u32 n + n bytes of JSON (the tables; {} in the words file), then one word section:
//   u32 count, u32 block, u32 len + the words, u32 len + the phonemes.
// Words are sorted by their UTF-8 bytes and front-coded, each ended by a newline: every block-th word is written
// whole, the others as one byte (leading bytes shared with the word before) + the rest.
// Phonemes, one run per word: its symbols (one byte each, an index into the tables' "lexiconSymbols") ended by
// 0xFF, or the single byte 0xFE: in the lexicon and said by the letter-to-sound model.
import Foundation

/// A lexicon entry: its phonemes, or "said by the letter-to-sound model".
enum LexEntry: Equatable {
    case said(String)
    case model
}

/// One .data file's word section, looked up in place (binary search over each block's whole word).
final class WordTable: @unchecked Sendable {
    static let magic: [UInt8] = Array("LKG2P13".utf8) + [1]
    private static let nl: UInt8 = 0x0A, end: UInt8 = 0xFF, model: UInt8 = 0xFE

    let document: [String: Any]
    let count: Int
    private let bytes: [UInt8]
    private let block: Int
    private var wOff: [Int] = [], pOff: [Int] = []
    private var heads: [Range<Int>] = []
    private let syms: [String]
    /// entries said by the letter-to-sound model
    private(set) var derived = 0

    init(url: URL, symbols: [String]? = nil) throws {
        let b = [UInt8](try Data(contentsOf: url, options: .mappedIfSafe))
        func fail(_ why: String) -> UserLexiconError { UserLexiconError(message: "Leokani G2P: \(url.lastPathComponent) \(why)") }
        guard b.count >= 12, Array(b[0..<8]) == Self.magic else { throw fail("is not a Leokani G2P 1.3 data file") }
        func u32(_ i: Int) throws -> Int {
            guard i + 4 <= b.count else { throw fail("is truncated") }
            return Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24
        }
        let n = try u32(8)
        guard 12 + n <= b.count, let doc = try? JSONSerialization.jsonObject(with: Data(b[12..<(12 + n)])) as? [String: Any] else {
            throw fail("has a damaged header")
        }
        var i = 12 + n
        count = try u32(i)
        block = try u32(i + 4)
        i += 8
        var parts: [Range<Int>] = []
        for _ in 0..<2 {
            let m = try u32(i)
            guard i + 4 + m <= b.count else { throw fail("is truncated") }
            parts.append((i + 4)..<(i + 4 + m))
            i += 4 + m
        }
        guard block > 0 else { throw fail("has a damaged header") }
        bytes = b
        document = doc
        guard let s = symbols ?? doc["lexiconSymbols"] as? [String] else { throw fail("has no lexiconSymbols") }
        syms = s
        // offsets of every block's first word and phoneme run; checks the section ends where it says
        var wi = parts[0].lowerBound, pi = parts[1].lowerBound
        func next(_ i: Int, _ r: Range<Int>, _ v: UInt8) throws -> Int {
            var j = i
            while j < r.upperBound, b[j] != v { j += 1 }
            guard j < r.upperBound else { throw fail("is truncated") }
            return j
        }
        for k in 0..<count {
            if k % block == 0 {
                wOff.append(wi); pOff.append(pi)
                let e = try next(wi, parts[0], Self.nl)
                heads.append(wi..<e)
                wi = e + 1
            } else {
                wi = try next(wi + 1, parts[0], Self.nl) + 1
            }
            guard pi < parts[1].upperBound else { throw fail("is truncated") }
            if b[pi] == Self.model { derived += 1; pi += 1 } else { pi = try next(pi, parts[1], Self.end) + 1 }
        }
    }

    private func compare(_ a: ArraySlice<UInt8>, _ q: [UInt8]) -> Int {
        for (x, y) in zip(a, q) where x != y { return Int(x) - Int(y) }
        return a.count - q.count
    }

    /// The entries of blocks from..<to, in order: (word bytes, entry).
    private func scan(_ from: Int, _ to: Int, _ body: ([UInt8], LexEntry) -> Bool) {
        var wi = wOff[from / block], pi = pOff[from / block]
        var prev: [UInt8] = []
        for k in from..<to {
            var w: [UInt8]
            if k % block == 0 {
                var e = wi
                while bytes[e] != Self.nl { e += 1 }
                w = Array(bytes[wi..<e])
                wi = e + 1
            } else {
                let p = Int(bytes[wi])
                var e = wi + 1
                while bytes[e] != Self.nl { e += 1 }
                w = Array(prev[0..<p]) + bytes[(wi + 1)..<e]
                wi = e + 1
            }
            prev = w
            let v: LexEntry
            if bytes[pi] == Self.model {
                v = .model
                pi += 1
            } else {
                var e = pi
                while bytes[e] != Self.end { e += 1 }
                v = .said((pi..<e).map { syms[Int(bytes[$0])] }.joined())
                pi = e + 1
            }
            if !body(w, v) { return }
        }
    }

    /// word -> its entry (nil: not in this table)
    subscript(key: String) -> LexEntry? {
        let q = Array(key.utf8)
        guard !heads.isEmpty, compare(bytes[heads[0]], q) <= 0 else { return nil }
        var lo = 0, hi = heads.count - 1
        while lo < hi {                                         // the last block whose first word <= q
            let mid = (lo + hi + 1) >> 1
            if compare(bytes[heads[mid]], q) <= 0 { lo = mid } else { hi = mid - 1 }
        }
        var found: LexEntry?
        scan(lo * block, min(count, (lo + 1) * block)) { w, v in
            let c = compare(w[...], q)
            if c == 0 { found = v }
            return c < 0
        }
        return found
    }

    /// every entry with its phonemes, as a dictionary (the common words: small, looked up for every word)
    func dictionary() -> [String: String] {
        var out: [String: String] = [:]
        out.reserveCapacity(count)
        if count > 0 {
            scan(0, count) { w, v in
                if case .said(let s) = v { out[String(decoding: w, as: UTF8.self)] = s }
                return true
            }
        }
        return out
    }
}

/// The 1.3 lexicon: the common words (decoded) + the other-words file (read on the first look-up that needs it).
final class DataLexicon: @unchecked Sendable {
    static let file = "leokani-g2p.data", wordsFile = "leokani-g2p-words.data"

    let document: [String: Any]
    private let common: [String: String]
    private let wordsURL: URL
    private let symbols: [String]
    private var rest: WordTable?
    private var restError: Error?
    private let lock = NSLock()

    init(directory: URL, lazy: Bool) throws {
        let core = try WordTable(url: directory.appendingPathComponent(Self.file))
        guard core.derived == 0 else { throw UserLexiconError(message: "Leokani G2P: \(Self.file) leaves common words to the letter-to-sound model") }
        document = core.document
        common = core.dictionary()
        symbols = core.document["lexiconSymbols"] as? [String] ?? []
        wordsURL = directory.appendingPathComponent(Self.wordsFile)
        guard FileManager.default.fileExists(atPath: wordsURL.path) else {
            throw UserLexiconError(message: "Leokani G2P: no \(Self.wordsFile) in \(directory.path)")
        }
        if !lazy { _ = try words() }
    }

    var loaded: Bool { lock.lock(); defer { lock.unlock() }; return rest != nil }

    @discardableResult
    func words() throws -> WordTable {
        lock.lock(); defer { lock.unlock() }
        if let rest { return rest }
        if let restError { throw restError }
        do {
            let t = try WordTable(url: wordsURL, symbols: symbols)
            rest = t
            return t
        } catch {
            restError = error
            throw error
        }
    }

    /// Says a word the lexicon leaves to the letter-to-sound model (set by LeokaniG2P once it is made).
    var say: ((String) -> String)?

    /// in the lexicon (without running the letter-to-sound model for a word it says)
    func contains(_ key: String) -> Bool {
        if common[key] != nil { return true }
        guard let t = try? words() else { return false }
        return t[key] != nil
    }

    /// true for a lexicon word the letter-to-sound model says
    func isModel(_ key: String) -> Bool {
        if common[key] != nil { return false }
        guard let t = try? words() else { return false }
        return t[key] == .model
    }

    subscript(key: String) -> String? {
        if let v = common[key] { return v }
        // the files were checked when the lexicon opened; a read failure later is a damaged install
        guard let t = try? words() else { return nil }
        switch t[key] {
        case .said(let s): return s
        case .model: return say?(key)
        case nil: return nil
        }
    }
}
