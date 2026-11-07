// SPDX-License-Identifier: MIT
// Leokani G2P by Milliwatt Labs (milliwattlabs.com)
//
// English text to Kokoro-style phonemes. Produces espeak compatible phoneme codes, made from the ground up: the same
// Kokoro/misaki-style codes Leokani-tts and Kokoro use. It contains no espeak-ng code or data files.
//
//     let g2p = try LeokaniG2P()                         // micro, the default
//     let mini = try LeokaniG2P(variant: .mini)          // larger: better on names and rare words
//     g2p.phonemize("Dr. Okafor lands at 7:45 AM.")       // a whole line -> one phoneme string
//     g2p.phonemizeChunks("A long paragraph. Of text.")    // -> one phoneme string per clause chunk
//     g2p.piece("the wind was cold")                       // one clause, no punctuation
//     try g2p.userLexicon.add("Siobhan", say: "shivawn")   // custom pronunciations
//
// Per piece: each word gets a base pronunciation (the lexicon, else the number reader for digits, else the
// letter-to-sound model), then the context model picks how each base is said in its clause and which words are
// written together. This is a port of leokani_g2p.py and reproduces its goldens.json exactly.
import Foundation
#if canImport(Compression)
import Compression
#endif

public final class LeokaniG2P: @unchecked Sendable {
    public static let format = "leokani-g2p/1"
    public static let version = "1.3.0"

    /// The model sizes. Both ship with the package: micro in model/, mini in model/mini/.
    public enum Variant: String, CaseIterable, Sendable {
        /// 2.2M letter-to-sound parameters (the default)
        case micro
        /// 2.9M letter-to-sound parameters: better on names and rare words
        case mini

        /// the folder holding this variant under a model folder
        public func directory(in base: URL) -> URL {
            self == .micro ? base : base.appendingPathComponent(rawValue, isDirectory: true)
        }
    }

    /// the variant this instance loaded
    public let variant: Variant

    /// custom pronunciations, checked before the lexicon (see UserLexicon)
    public let userLexicon: UserLexicon
    /// the phoneme symbols the models produce (a custom pronunciation may use these, ˈ, ˌ and spaces)
    public let phonemeSymbols: [String]

    let lexicon: Lexicon
    let cased: [String: String]
    let variants: [String: [String]]
    let wordIds: [String: Int]
    let symIds: [String: Int]
    let chars: [String: Int]
    let outSyms: [String]
    let symbolWords: [String: String]
    let numbers: Numbers
    let normalizer: Normalizer
    private let directory: URL
    private var _oov: OOVModel?
    private var _context: ContextModel?
    /// the letter-to-sound models (started on the first unknown word when lazy)
    var oovModel: OOVModel {
        if let m = _oov { return m }
        do {
            let m = try OOVModel(encoder: directory.appendingPathComponent("oov-encoder.onnx"),
                                 decoder: directory.appendingPathComponent("oov-decoder.onnx"))
            _oov = m
            return m
        } catch { fatalError("Leokani G2P: \(error)") }       // the files were there when the instance opened
    }
    /// the context model (started on the first piece when lazy)
    var context: ContextModel {
        if let m = _context { return m }
        do {
            let m = try ContextModel(url: directory.appendingPathComponent("context.onnx"))
            _context = m
            return m
        } catch { fatalError("Leokani G2P: \(error)") }
    }
    let maxOut: Int
    private var cache: [String: String] = [:]
    private let lock = NSRecursiveLock()

    /// The model files that ship with this package (micro; mini is in its mini/ subfolder).
    public static var bundledModelDirectory: URL? { Bundle.module.url(forResource: "model", withExtension: nil) }

    /// The bundled model files of one variant.
    public static func bundledModelDirectory(_ variant: Variant) -> URL? {
        bundledModelDirectory.map { variant.directory(in: $0) }
    }

    /// - Parameters:
    ///   - modelDirectory: a folder with the model files (1.3: leokani-g2p.data, leokani-g2p-words.data; 1.2:
    ///     leokani-g2p.json.gz or leokani-g2p.json) and the three .onnx files; nil uses the files bundled with the
    ///     package.
    ///   - variant: .micro (default) or .mini, looked up under modelDirectory (mini: its mini/ subfolder).
    ///   - userLexicon: custom pronunciations to start with (it stays live: entries added later apply too).
    ///   - compactLexicon: a leokani-g2p.lex (scripts/make_lex.py) for this variant: the document and the lexicon
    ///     come from it, memory-mapped, instead of from leokani-g2p.json.gz (much less memory, much faster to open).
    ///   - lazy: read the other-words file and start each model only when a piece first needs it (1.3 files;
    ///     default false: everything now).
    public init(modelDirectory: URL? = nil, variant: Variant = .micro, userLexicon: UserLexicon? = nil,
                compactLexicon: URL? = nil, lazy: Bool = false) throws {
        guard let base = modelDirectory ?? LeokaniG2P.bundledModelDirectory else {
            throw UserLexiconError(message: "Leokani G2P: no model directory")
        }
        let dir = variant.directory(in: base)
        self.variant = variant
        var mapped: CompactLexicon?
        var packed: DataLexicon?
        if let compactLexicon {
            mapped = try CompactLexicon(url: compactLexicon)
        } else if FileManager.default.fileExists(atPath: dir.appendingPathComponent(DataLexicon.file).path) {
            packed = try DataLexicon(directory: dir, lazy: lazy)
        }
        let doc = try mapped?.document ?? packed?.document ?? LeokaniG2P.readDocument(dir)
        guard doc["format"] as? String == LeokaniG2P.format else {
            throw UserLexiconError(message: "\(dir.path): not a \(LeokaniG2P.format) model")
        }
        func dict<T>(_ k: String) throws -> T {
            guard let v = doc[k] as? T else { throw UserLexiconError(message: "Leokani G2P: model file has no \(k)") }
            return v
        }
        if let mapped { lexicon = .mapped(mapped) } else if let packed { lexicon = .data(packed) } else { lexicon = .decoded(try dict("lexicon")) }
        cased = try dict("cased")
        variants = try dict("variants")
        let cw: [String] = try dict("contextWords")
        var ids: [String: Int] = [:]
        ids.reserveCapacity(cw.count)
        for (i, w) in cw.enumerated() where ids[w] == nil { ids[w] = i + 2 }
        wordIds = ids
        let syms: [String] = try dict("symbols")
        symIds = Dictionary(syms.enumerated().map { ($0.element, $0.offset + 2) }, uniquingKeysWith: { a, _ in a })
        let ch: [String] = try dict("chars")
        chars = Dictionary(ch.enumerated().map { ($0.element, $0.offset + 4) }, uniquingKeysWith: { a, _ in a })
        outSyms = try dict("outSymbols")
        symbolWords = try dict("symbolWords")
        let atoms: [String: String] = try dict("numberAtoms")
        let oov: [String: Any] = try dict("oov")
        maxOut = (oov["maxOut"] as? Int) ?? 48
        phonemeSymbols = outSyms

        var letters: [String: String] = [:]
        for (k, v) in atoms where k.hasPrefix("letter:") { letters[String(k.dropFirst(7))] = v }
        letters["s"] = "ˈɛs"                                  // the atom is the plural suffix ("80s")

        let lex = lexicon, cs = cased, wi = ids, vars = variants
        numbers = Numbers(atoms, word: { w in cs[w] ?? lex[w.lower] })
        normalizer = Normalizer(known: { lex.contains($0) }, letters: letters, cased: { cs[$0] != nil },
                                common: { wi[$0] != nil },
                                reading: { w in (lex[w].map { [$0] } ?? []) + (vars[w] ?? []) })
        directory = dir
        if lazy {
            for f in ["oov-encoder.onnx", "oov-decoder.onnx", "context.onnx"]
            where !FileManager.default.fileExists(atPath: dir.appendingPathComponent(f).path) {
                throw UserLexiconError(message: "Leokani G2P: no \(f) in \(dir.path)")
            }
        } else {
            _oov = try OOVModel(encoder: dir.appendingPathComponent("oov-encoder.onnx"),
                                decoder: dir.appendingPathComponent("oov-decoder.onnx"))
            _context = try ContextModel(url: dir.appendingPathComponent("context.onnx"))
        }

        var allowed = Set<Unicode.Scalar>()
        for s in outSyms { allowed.formUnion(s.unicodeScalars) }
        allowed.formUnion([PRIMARY.unicodeScalars.first!, SECONDARY.unicodeScalars.first!])
        allowed.remove(" ")
        let ul = UserLexicon(symbols: allowed)
        if let userLexicon { try ul.merge(userLexicon) }
        self.userLexicon = ul
        normalizer.user = ul
        if case .data(let d) = lexicon { d.say = { [unowned self] w in self.oov([w])[0] } }
    }

    // MARK: - public API

    /// Which parts are in memory: "words" (the other-words file) and the models ("enc", "dec", "ctx").
    public func loaded() -> [String] {
        lock.lock(); defer { lock.unlock() }
        var out: [String] = []
        if case .data(let d) = lexicon { if d.loaded { out.append("words") } } else { out.append("words") }
        if _oov != nil { out += ["enc", "dec"] }
        if _context != nil { out.append("ctx") }
        return out
    }

    /// A line or paragraph -> one Kokoro phoneme string (the clause chunks joined by a space).
    public func phonemize(_ text: String) -> String { phonemizeChunks(text).joined(separator: " ") }

    /// A line or paragraph -> Kokoro phonemes, one string per clause chunk (the unit Leokani-tts speaks):
    /// normalise, clean, chunk, split into pieces.
    public func phonemizeChunks(_ text: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return chunks(clean(normalizer(text))).map { line($0) }
    }

    /// One clause (words with no punctuation between them) -> phonemes.
    public func piece(_ piece: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return pieceWords(piece).phonemes
    }

    /// A line as a person reads it (money, dates, units, abbreviations ... as words).
    public func normalize(_ text: String, pauses: Bool = true) -> String {
        lock.lock(); defer { lock.unlock() }
        return normalizer(text, pauses: pauses)
    }

    /// Add custom pronunciations from a .json or .tsv file.
    public func loadUserLexicon(contentsOf url: URL) throws { try userLexicon.load(contentsOf: url) }

    // MARK: - a line

    func line(_ text: String) -> String {
        var out = ""
        for p in pieces(text) {
            if clusters(p).allSatisfy({ PUNCT.contains($0) }) {
                out += p
                continue
            }
            let ph = pieceWords(desilence(p)).phonemes
            if ph.isEmpty { continue }
            if !out.isEmpty, !out.ends(" ") { out += " " }
            out += ph
        }
        return out.pyStrip
    }

    // MARK: - bases

    func base(_ w: String) -> (String, String) {
        if w.has(PH) { return (w.split1(PH)[1], "lexicon") }
        if let c = cased[w] { return (c, "lexicon") }
        let lw = w.lower
        if let l = lexicon[lw] { return (l, "lexicon") }
        if w.anyDigit {
            if let said = numbers.say(w) { return (said, "number") }
            let runs = RX.get("\\d+|[\\p{L}\\p{Nl}\\p{No}]+").findall(w)
            if !runs.isEmpty, runs != [w] || !runs[0].unicodeScalars.elementsEqual(w.unicodeScalars) {
                return (runs.map { base($0).0 }.filter { !$0.isEmpty }.joined(separator: " "), "number")
            }
        }
        if let s = symbolWords[w] { return (s, "symbol") }
        if !w.anyAlpha { return ("", "empty") }
        let r = w.rstrip(".")
        if w.ends("."), !r.isEmpty, !r.has(".") { return base(r) }
        return (oov([w])[0], "oov")
    }

    func oov(_ words: [String]) -> [String] {
        for w in words where cache[w] == nil {
            cache[w] = splitLong(w).map { decodeWord($0) }.joined()
        }
        return words.map { cache[$0]! }
    }

    private var partCache: [String: String] = [:]

    func decodeWord(_ w: String) -> String {
        if let c = partCache[w] { return c }
        let ids = [2] + w.chars.map { chars[$0] ?? 3 } + [1]
        let mem = oovModel.encode(ids)
        let toks = oovModel.decode(memory: mem, n: ids.count, maxOut: maxOut)
        let s = toks.map { $0 >= 4 ? outSyms[$0 - 4] : "" }.joined()
        partCache[w] = s
        return s
    }

    func needsOOV(_ w0: String) -> Bool {
        var w = w0
        let r = w.rstrip(".")
        if w.ends("."), !r.isEmpty, !r.has(".") { w = r }
        let lw = w.lower
        return !w.has(PH) && cased[w] == nil && !lexicon.contains(lw) && symbolWords[w] == nil && w.anyAlpha
            && !(w.anyDigit && numbers.say(w) != nil)
    }

    // MARK: - a piece

    struct PieceResult { let phonemes: String; let forms: [String]; let joins: [Bool]; let sources: [String] }

    func pieceWords(_ piece: String) -> PieceResult {
        var words = normalizer(piece, pauses: false).splitOn(" ").filter { !$0.isEmpty }
        if words.isEmpty { return PieceResult(phonemes: "", forms: [], joins: [], sources: []) }
        let need = words.filter { needsOOV($0) }
        if !need.isEmpty { _ = oov(Array(Set(need)).sorted()) }
        let bs = words.map { base($0) }
        let bases = bs.map { $0.0 }, srcs = bs.map { $0.1 }
        let given = words.map { $0.has(PH) }
        words = words.map { $0.split1(PH)[0] }
        let feats = features(words, bases, srcs)
        let (form, join) = context.run(feats)
        var forms: [String] = []
        for i in 0..<words.count {
            let b = bases[i]
            var p: String?
            if given[i] {
                var logits = form[i]
                if !b.ends("ɹ") {
                    var j = EDGE_OPS.firstIndex(of: "linkr")!
                    while j < logits.count { logits[j] = -.infinity; j += EDGE_OPS.count }
                }
                p = pick(logits, candidates(b, []))
            } else {
                p = pick(form[i], candidates(b, variants[words[i].lower] ?? []))
            }
            forms.append((p ?? "").isEmpty ? b : p!)
        }
        let joins = join.map { $0.count > 1 && $0[1] > $0[0] }
        return PieceResult(phonemes: assemble(forms, joins), forms: forms, joins: joins, sources: srcs)
    }

    func features(_ words: [String], _ bases: [String], _ srcs: [String]) -> [[Int]] {
        let n = words.count
        var out: [[Int]] = []
        for i in 0..<n {
            let w = words[i], b = bases[i]
            let bb = bareStress(b).rep(" ", "")
            let bl = bb.pyLen
            out.append([
                wordIds[w.lower] ?? 1,
                SHAPES.firstIndex(of: shape(w))!,
                bl > 0 ? symIds[bb.sl(nil, 1)] ?? 1 : 0,
                bl > 0 ? symIds[bb.sl(-1)] ?? 1 : 0,
                bl > 1 ? symIds[bb.sl(-2, -1)] ?? 1 : 0,
                min(b.count(of: PRIMARY), 3),
                min(b.count(of: SECONDARY), 3),
                min(bb.chars.filter { VOWELS.contains($0) }.count, 7),
                min(b.isEmpty ? 0 : b.count(of: " ") + 1, 3),
                SRC.firstIndex(of: srcs[i])!,
                i == 0 ? 1 : 0,
                i == n - 1 ? 1 : 0,
                min(i, 7),
                min(n - 1 - i, 7),
            ])
        }
        return out
    }
}

// MARK: - stress and phoneme edits

func stressOp(_ b: String, _ op: String) -> String {
    switch op {
    case "same": return b
    case "demote": return b.rep(PRIMARY, SECONDARY)
    case "strip": return bareStress(b)
    case "promote1":
        let i = b.find(SECONDARY)
        return i < 0 ? b : b.sl(nil, i) + PRIMARY + b.sl(i + 1)
    case "demote1":
        let i = b.find(PRIMARY)
        return i < 0 ? b : b.sl(nil, i) + SECONDARY + b.sl(i + 1)
    case "demoteLast":
        let i = b.rfind(PRIMARY)
        return i < 0 ? b : b.sl(nil, i) + SECONDARY + b.sl(i + 1)
    case "promote": return b.rep(SECONDARY, PRIMARY)
    default: return b
    }
}

func edgeOp(_ s: String, _ op: String) -> String {
    if op == "none" || s.isEmpty { return s }
    switch op {
    case "flap": return s.ends("t") ? s.sl(nil, -1) + "ɾ" : s
    case "linkr": return s + "ɹ"
    case "unflap": return s.ends("ɾ") ? s.sl(nil, -1) + "t" : s
    default: return s
    }
}

func candidates(_ base: String, _ variants: [String]) -> [String?] {
    STRESS_OPS.map { stressOp(base, $0) } + (0..<N_VARIANTS).map { $0 < variants.count ? variants[$0] : nil }
}

func shape(_ w: String) -> String {
    if w.anyDigit { return "digit" }
    if !w.anyAlpha { return "other" }
    if w.unicodeScalars.elementsEqual(w.lower.unicodeScalars) { return "lower" }
    if w.pyIsUpper { return "caps" }
    let rest = w.sl(1)
    if w.firstIsUpper, rest.unicodeScalars.elementsEqual(rest.lower.unicodeScalars) { return "title" }
    return "mixed"
}

/// the best (slot, edge) pair the word has: logits over candidates × EDGE_OPS, slot-major; ties keep the lower index
func pick(_ logits: [Float], _ cands: [String?]) -> String? {
    let order = logits.indices.sorted { a, b in logits[a] != logits[b] ? logits[a] > logits[b] : a < b }
    for j in order {
        let k = j / EDGE_OPS.count, e = j % EDGE_OPS.count
        if k < cands.count, let c = cands[k] { return edgeOp(c, EDGE_OPS[e]) }
    }
    return nil
}

func assemble(_ forms: [String], _ joins: [Bool]) -> String {
    var out = ""
    for (i, f) in forms.enumerated() where !f.isEmpty {
        if !out.isEmpty, !out.ends(" "), !(i > 0 && joins[i - 1] && !forms[i - 1].isEmpty) { out += " " }
        out += f
    }
    return out.pyStrip
}

func splitLong(_ w: String) -> [String] {
    let s = w.sc
    if s.count <= LONG_WORD { return [w] }
    let n = (s.count + PART - 1) / PART
    let size = Double(s.count) / Double(n)
    var cuts: [Int] = []
    var last = 0
    let vowels = Set("aeiouy".unicodeScalars)
    func isV(_ c: Unicode.Scalar) -> Bool {
        let l = String(c).lower
        return l.unicodeScalars.count == 1 && vowels.contains(l.unicodeScalars.first!)
    }
    for k in 1..<n {
        let aim = Int((Double(k) * size).rounded(.toNearestOrEven))     // Python's round()
        var best = aim
        for d in [0, 1, -1, 2, -2, 3, -3] {
            let j = aim + d
            if last < j, j < s.count, isV(s[j - 1]), !isV(s[j]) { best = j; break }
        }
        cuts.append(best)
        last = best
    }
    let starts = [0] + cuts, ends = cuts + [s.count]
    return zip(starts, ends).compactMap { a, b in a < b ? String(scalars: s[a..<b]) : nil }
}

extension UserLexicon {
    func merge(_ other: UserLexicon) throws {
        for (k, v) in other.entries() { try add(k, v) }
    }
}

// MARK: - the model document

extension LeokaniG2P {
    static func readDocument(_ dir: URL) throws -> [String: Any] {
        let plain = dir.appendingPathComponent("leokani-g2p.json")
        let gz = dir.appendingPathComponent("leokani-g2p.json.gz")
        let data: Data
        if FileManager.default.fileExists(atPath: plain.path) {
            data = try Data(contentsOf: plain)
        } else {
            data = try gunzip(try Data(contentsOf: gz))
        }
        guard let doc = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UserLexiconError(message: "Leokani G2P: model file is not a JSON object")
        }
        return doc
    }

    static func gunzip(_ d: Data) throws -> Data {
        #if canImport(Compression)
        let b = [UInt8](d)
        guard b.count > 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { throw UserLexiconError(message: "Leokani G2P: not a gzip file") }
        let flg = b[3]
        var i = 10
        if flg & 4 != 0 { i += 2 + Int(b[i]) | Int(b[i + 1]) << 8 }
        if flg & 8 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flg & 16 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flg & 2 != 0 { i += 2 }
        let n = b.count
        let isize = Int(b[n - 4]) | Int(b[n - 3]) << 8 | Int(b[n - 2]) << 16 | Int(b[n - 1]) << 24
        var out = [UInt8](repeating: 0, count: isize + 1)
        let got = b[i..<(n - 8)].withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                compression_decode_buffer(dst.baseAddress!, dst.count, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard got == isize else { throw UserLexiconError(message: "Leokani G2P: gzip data is damaged") }
        return Data(out[0..<got])
        #else
        throw UserLexiconError(message: "Leokani G2P: gunzip leokani-g2p.json.gz to leokani-g2p.json on this platform")
        #endif
    }
}

// MARK: - chunks with their text

extension LeokaniG2P {
    /// One clause chunk: the (normalised, cleaned) text it came from and its phonemes.
    public struct Chunk: Sendable, Equatable {
        public let text: String
        public let phonemes: String
    }

    /// phonemizeChunks with each chunk's text beside its phonemes (the same chunks, in order).
    public func phonemizeDetailed(_ text: String) -> [Chunk] {
        lock.lock(); defer { lock.unlock() }
        return chunks(clean(normalizer(text))).map { Chunk(text: $0, phonemes: line($0)) }
    }
}
