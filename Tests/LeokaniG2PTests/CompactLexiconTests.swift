// SPDX-License-Identifier: MIT
import XCTest
@testable import LeokaniG2P

/// The memory-mapped lexicon (leokani-g2p.lex) gives exactly the goldens the decoded one does.
final class CompactLexiconTests: XCTestCase {
    static func lex(_ v: LeokaniG2P.Variant) throws -> URL {
        // .lex is made from a 1.2 model (leokani-g2p.json.gz); a 1.3 model's .data files are read in place already.
        guard let base = LeokaniG2P.bundledModelDirectory,
              FileManager.default.fileExists(atPath: base.appendingPathComponent("leokani-g2p.json.gz").path) else {
            throw XCTSkip("the bundled model is a 1.3 build: its .data lexicon is the compact form")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("leokani-g2p-\(v.rawValue)-\(getpid()).lex")
        if !FileManager.default.fileExists(atPath: url.path) { try LeokaniG2P.writeCompactLexicon(variant: v, to: url) }
        return url
    }

    func testCompactGoldens() throws {
        let g = try LeokaniG2P(compactLexicon: try Self.lex(.micro))
        guard case .mapped(let m) = g.lexicon else { return XCTFail("not mapped") }
        XCTAssertGreaterThan(m.count, 500_000)
        try GoldensTests.check(g, "goldens.json")
    }

    func testCompactGoldensMini() throws {
        let g = try LeokaniG2P(variant: .mini, compactLexicon: try Self.lex(.mini))
        try GoldensTests.check(g, "goldens-mini.json")
    }

    func testCompactLookups() throws {
        let m = try CompactLexicon(url: try Self.lex(.micro))
        XCTAssertNotNil(m["the"])
        XCTAssertNil(m["zzzzqqqxx"])
        XCTAssertNil(m[""] ?? nil == nil ? nil : "x")
    }

    /// LV-2 budget: opening the mapped lexicon is fast (the decoded one takes ~0.4 s on a phone).
    func testCompactOpensFast() throws {
        let url = try Self.lex(.micro)
        let t = Date()
        _ = try LeokaniG2P(compactLexicon: url)
        let s = Date().timeIntervalSince(t)
        print("compact G2P load: \(Int(s * 1000)) ms")
        XCTAssertLessThan(s, 1.0)
    }
}
