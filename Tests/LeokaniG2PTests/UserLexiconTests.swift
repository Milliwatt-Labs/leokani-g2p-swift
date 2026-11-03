// SPDX-License-Identifier: MIT
import XCTest
@testable import LeokaniG2P

final class UserLexiconTests: XCTestCase {
    /// user-lexicon-goldens.json (shared by every port): load 'lexicon' and 'tsv', reproduce every case,
    /// reject every 'reject' document; with no user lexicon, 'without' comes back.
    func testSharedVectors() throws {
        let doc = Shared.json("user-lexicon-goldens.json")
        let lexJSON = try JSONSerialization.data(withJSONObject: doc["lexicon"]!)
        let rawFile = try Data(contentsOf: Shared.resource("user-lexicon-goldens.json"))
        for source in ["json", "tsv"] {
            let ul = UserLexicon()
            if source == "json" {
                // the document's own bytes keep the key order; re-encoded JSON is a second check
                try ul.load(json: try Self.lexiconBytes(rawFile) ?? lexJSON)
            } else {
                try ul.load(tsv: doc["tsv"] as! String)
            }
            let g = try LeokaniG2P(modelDirectory: LeokaniG2P.bundledModelDirectory, userLexicon: ul)
            for sec in ["lines", "pieces"] {
                for c in (doc[sec] as? [[String: Any]]) ?? [] {
                    let text = (c["text"] ?? c["piece"]) as! String
                    let mode = (c["mode"] as? String) ?? (sec == "pieces" ? "piece" : "line")
                    if let want = c["normalized"] as? String {
                        let got = mode == "piece" ? g.normalize(text, pauses: false) : g.normalize(text)
                        XCTAssertTrue(got.unicodeScalars.elementsEqual(want.unicodeScalars), "\(source) normalize \(text): want \(want) got \(got)")
                    }
                    let want = c["leokani"] as! String
                    let got = mode == "piece" ? g.piece(text) : g.phonemize(text)
                    XCTAssertTrue(got.unicodeScalars.elementsEqual(want.unicodeScalars), "\(source) \(text): want \(want) got \(got)")
                    if let without = c["without"] as? String {
                        let plain = mode == "piece" ? Shared.g2p.piece(text) : Shared.g2p.phonemize(text)
                        XCTAssertTrue(plain.unicodeScalars.elementsEqual(without.unicodeScalars), "without \(text): want \(without) got \(plain)")
                    }
                }
            }
        }
        for r in (doc["reject"] as? [Any]) ?? [] {
            let ul = UserLexicon(symbols: Self.symbols)
            if let s = r as? String {
                XCTAssertThrowsError(try ul.load(tsv: s), "should reject TSV \(s)")
            } else if let o = r as? [String: Any], let tsv = o["tsv"] as? String {
                XCTAssertThrowsError(try ul.load(tsv: tsv), "should reject TSV \(tsv)")
            } else {
                let body: Any = (r as? [String: Any])?["json"] ?? (r as? [String: Any])?["doc"] ?? r
                let data = try (body as? String).map { Data($0.utf8) } ?? (JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed]))
                XCTAssertThrowsError(try ul.load(json: data), "should reject \(String(decoding: data, as: UTF8.self))")
            }
        }
    }

    static var symbols: Set<Unicode.Scalar> {
        var s = Set<Unicode.Scalar>()
        for x in Shared.g2p.phonemeSymbols { s.formUnion(x.unicodeScalars) }
        s.formUnion(["ˈ", "ˌ"]); s.remove(" ")
        return s
    }

    /// the "lexicon" member's raw bytes from the vectors file
    static func lexiconBytes(_ file: Data) throws -> Data? {
        guard let text = String(data: file, encoding: .utf8), let r = text.range(of: "\"lexicon\"") else { return nil }
        var i = text[r.upperBound...].firstIndex(of: "{")!
        let start = i
        var depth = 0, inStr = false, esc = false
        while i < text.endIndex {
            let c = text[i]
            if inStr { if esc { esc = false } else if c == "\\" { esc = true } else if c == "\"" { inStr = false } }
            else if c == "\"" { inStr = true }
            else if c == "{" { depth += 1 }
            else if c == "}" { depth -= 1; if depth == 0 { return Data(text[start...i].utf8) } }
            i = text.index(after: i)
        }
        return nil
    }

    func testCaseAndPossessives() throws {
        let g = try LeokaniG2P(modelDirectory: LeokaniG2P.bundledModelDirectory)
        try g.userLexicon.add("Gauss", phonemes: "ɡˈWs")
        try g.userLexicon.add("Hattie", "/hˈæɾi/")
        try g.userLexicon.add("Milliwatt", "/mˈɪliwˌɑt/")
        try g.userLexicon.add("nguyen", say: "win")
        // a capitalised key matches only that casing
        XCTAssertTrue(g.normalize("Gauss").contains("\u{E000}ɡˈWs"))
        XCTAssertFalse(g.normalize("gauss").contains("\u{E000}"))
        // a lowercase key matches any casing
        XCTAssertEqual(g.normalize("NGUYEN Nguyen nguyen"), "win win win")
        // possessives: after a sibilant, a voiceless consonant, anything else
        XCTAssertEqual(g.normalize("Gauss's"), "Gauss's\u{E000}ɡˈWsᵻz")
        XCTAssertEqual(g.normalize("Milliwatt’s"), "Milliwatt’s\u{E000}mˈɪliwˌɑts")
        XCTAssertEqual(g.normalize("Hattie's"), "Hattie's\u{E000}hˈæɾiz")
        XCTAssertEqual(g.normalize("Nguyen's"), "win's")
        // punctuation around the word stays
        XCTAssertEqual(g.normalize("(Hattie)!"), "(Hattie\u{E000}hˈæɾi)!")
    }

    func testLoaderErrors() throws {
        let g = Shared.g2p
        let ul = UserLexicon(symbols: Self.symbols)
        XCTAssertThrowsError(try ul.add("two words", say: "x"))
        XCTAssertThrowsError(try ul.add("x", phonemes: "q!"))          // not a phoneme symbol
        XCTAssertThrowsError(try ul.add("x", say: "   "))
        XCTAssertThrowsError(try ul.load(tsv: "no tab here"))
        XCTAssertThrowsError(try ul.load(json: Data("{\"format\": \"other/1\", \"words\": {}}".utf8)))
        XCTAssertThrowsError(try ul.load(json: Data("{\"a\": {\"phonemes\": \"æ\", \"say\": \"a\"}}".utf8)))
        XCTAssertThrowsError(try ul.load(json: Data("[1, 2]".utf8)))
        try ul.load(tsv: "# comment\n\nLeokani\t/lˌAOkˈɑni/\nSiobhan\tshivawn\n")
        XCTAssertEqual(ul.count, 2)
        XCTAssertEqual(g.userLexicon.count, 0, "the shared instance has no user entries")
    }

    func testLaterEntriesReplaceEarlier() throws {
        let ul = UserLexicon()
        try ul.load(json: Data("{\"format\": \"leokani-g2p-user/1\", \"words\": {\"gif\": \"/ɡˈɪf/\", \"gif\": \"/ʤˈɪf/\"}}".utf8))
        XCTAssertEqual(ul.rewrite("gif"), .phonemes("ʤˈɪf"))
    }

    func testEmptyUserLexiconChangesNothing() {
        let g = Shared.g2p
        XCTAssertEqual(g.userLexicon.count, 0)
        XCTAssertEqual(g.phonemize("Dr. Lindqvist lives on Pine St. near the park."),
                       "dˈɑktəɹ lˈɪndkvɪst lˈɪvz ˌɔn pˈIn stɹˈit nˌɪɹ ðə pˈɑɹk.")
    }
}
