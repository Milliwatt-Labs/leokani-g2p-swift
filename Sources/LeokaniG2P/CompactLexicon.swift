// SPDX-License-Identifier: MIT
// Leokani G2P by Milliwatt Labs (milliwattlabs.com)
//
// The lexicon as a memory-mapped sorted table (scripts/make_lex.py writes it). Its pages are clean and file-backed,
// so the ~570k entries cost almost no dirty memory, and opening it takes a few milliseconds instead of decoding
// 18 MB of JSON into dictionaries. Keys compare as UTF-8 bytes, which is code-point equality, as the reference has.
import Foundation

final class CompactLexicon: @unchecked Sendable {
    static let magic = Array("LKLX0001".utf8)

    /// the model document without its lexicon (the header JSON)
    let document: [String: Any]
    let count: Int
    private let base: UnsafeRawPointer
    private let length: Int
    private let off: UnsafePointer<UInt32>
    private let mid: UnsafePointer<UInt32>
    private let blob: UnsafePointer<UInt8>

    init(url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw UserLexiconError(message: "Leokani G2P: can't open \(url.lastPathComponent)") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > 16 else { throw UserLexiconError(message: "Leokani G2P: \(url.lastPathComponent) is empty") }
        let n = Int(st.st_size)
        guard let p = mmap(nil, n, PROT_READ, MAP_PRIVATE, fd, 0), p != MAP_FAILED else {
            throw UserLexiconError(message: "Leokani G2P: can't map \(url.lastPathComponent)")
        }
        let raw = UnsafeRawPointer(p)
        func fail(_ why: String) -> UserLexiconError {
            munmap(p, n)
            return UserLexiconError(message: "Leokani G2P: \(url.lastPathComponent) \(why)")
        }
        let b = raw.assumingMemoryBound(to: UInt8.self)
        guard Array(UnsafeBufferPointer(start: b, count: 8)) == Self.magic else { throw fail("is not a compact lexicon") }
        func u32(_ at: Int) -> Int { Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: UInt32.self))) }
        let h = u32(8)
        guard 12 + h + 4 <= n else { throw fail("is truncated") }
        let head = Data(bytes: raw + 12, count: h)
        guard let doc = try? JSONSerialization.jsonObject(with: head) as? [String: Any] else { throw fail("has a damaged header") }
        var at = 12 + h
        at = (at + 3) & ~3
        let entries = u32(at)
        at += 4
        let tables = (2 * entries + 1) * 4
        guard at + tables <= n else { throw fail("is truncated") }
        let o = (raw + at).assumingMemoryBound(to: UInt32.self)
        guard at + tables + Int(UInt32(littleEndian: o[entries])) <= n else { throw fail("is truncated") }
        base = raw
        length = n
        off = o
        mid = (raw + at + (entries + 1) * 4).assumingMemoryBound(to: UInt32.self)
        blob = (raw + at + tables).assumingMemoryBound(to: UInt8.self)
        count = entries
        document = doc
    }

    deinit { munmap(UnsafeMutableRawPointer(mutating: base), length) }

    subscript(key: String) -> String? {
        var key = key
        return key.withUTF8 { q -> String? in
            var lo = 0, hi = count
            while lo < hi {
                let m = (lo + hi) >> 1
                let ks = Int(off[m]), ke = Int(mid[m])
                let kl = ke - ks
                let c = memcmp(blob + ks, q.baseAddress!, min(kl, q.count))
                let order = c != 0 ? Int(c) : kl - q.count
                if order == 0 {
                    let ve = Int(off[m + 1])
                    return String(decoding: UnsafeBufferPointer(start: blob + ke, count: ve - ke), as: UTF8.self)
                }
                if order < 0 { lo = m + 1 } else { hi = m }
            }
            return nil
        }
    }
}

/// The lexicon decoded (from leokani-g2p.json.gz), mapped (from leokani-g2p.lex) or packed (1.3's .data files).
enum Lexicon: @unchecked Sendable {
    case decoded([String: String])
    case mapped(CompactLexicon)
    case data(DataLexicon)

    subscript(key: String) -> String? {
        switch self {
        case .decoded(let d): return d[key]
        case .mapped(let m): return key.isEmpty ? nil : m[key]
        case .data(let d): return d[key]
        }
    }
}

extension Lexicon {
    /// in the lexicon (a 1.3 lexicon word the letter-to-sound model says is not run for this)
    func contains(_ key: String) -> Bool {
        if case .data(let d) = self { return d.contains(key) }
        return self[key] != nil
    }

    /// a 1.3 lexicon word the letter-to-sound model says
    func isModel(_ key: String) -> Bool {
        if case .data(let d) = self { return d.isModel(key) }
        return false
    }
}

extension LeokaniG2P {
    /// Write the compact lexicon (the same bytes scripts/make_lex.py writes) for one variant's model files.
    /// Decoding the JSON takes the full lexicon's memory once, so do this at build time or in an app, not an extension.
    public static func writeCompactLexicon(modelDirectory: URL? = nil, variant: Variant = .micro, to url: URL) throws {
        guard let base = modelDirectory ?? bundledModelDirectory else { throw UserLexiconError(message: "Leokani G2P: no model directory") }
        var doc = try readDocument(variant.directory(in: base))
        guard let lex = doc.removeValue(forKey: "lexicon") as? [String: String] else {
            throw UserLexiconError(message: "Leokani G2P: model file has no lexicon")
        }
        let head = try JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys, .withoutEscapingSlashes])
        let items = lex.map { (Array($0.key.utf8), Array($0.value.utf8)) }.sorted { $0.0.lexicographicallyPrecedes($1.0) }
        var out = Data(CompactLexicon.magic)
        func put(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        put(head.count)
        out.append(head)
        while out.count % 4 != 0 { out.append(0) }
        put(items.count)
        var off: [Int] = [], mid: [Int] = [], at = 0
        for (k, v) in items { off.append(at); at += k.count; mid.append(at); at += v.count }
        off.append(at)
        off.forEach(put)
        mid.forEach(put)
        for (k, v) in items { out.append(contentsOf: k); out.append(contentsOf: v) }
        try out.write(to: url, options: .atomic)
    }
}
