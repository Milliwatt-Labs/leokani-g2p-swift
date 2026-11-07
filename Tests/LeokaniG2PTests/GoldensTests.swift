// SPDX-License-Identifier: MIT
import XCTest
@testable import LeokaniG2P

/// One shared instance: loading the lexicon and the three models takes a moment.
enum Shared {
    static let g2p: LeokaniG2P = try! LeokaniG2P()
    static let mini: LeokaniG2P = try! LeokaniG2P(variant: .mini)
    static func resource(_ name: String) -> URL {
        Bundle.module.url(forResource: "Fixtures/" + name, withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil)!
    }
    static func json(_ name: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(contentsOf: resource(name))) as! [String: Any]
    }
}

final class GoldensTests: XCTestCase {
    /// goldens.json: every 'normalized' and 'leokani' string, exactly (pieces through piece(), lines and edge
    /// through the whole front end).
    func testGoldens() throws { try Self.check(Shared.g2p, "goldens.json") }

    /// goldens-mini.json on the mini variant.
    func testGoldensMini() throws {
        XCTAssertEqual(Shared.mini.variant, .mini)
        try Self.check(Shared.mini, "goldens-mini.json")
    }

    static func check(_ g: LeokaniG2P, _ file: String) throws {
        let doc = Shared.json(file)
        XCTAssertEqual(doc["format"] as? String, "leokani-g2p/1")
        var checks = 0
        var misses: [String] = []
        for p in doc["pieces"] as! [[String: String]] {
            checks += 2
            let n = g.normalize(p["piece"]!, pauses: false)
            if n != p["normalized"]! || !n.unicodeScalars.elementsEqual(p["normalized"]!.unicodeScalars) {
                misses.append("piece-normalized \(p["piece"]!)\n  want \(p["normalized"]!)\n  got  \(n)")
            }
            let ph = g.piece(p["piece"]!)
            if !ph.unicodeScalars.elementsEqual(p["leokani"]!.unicodeScalars) {
                misses.append("piece \(p["piece"]!)\n  want \(p["leokani"]!)\n  got  \(ph)")
            }
        }
        for sec in ["lines", "edge"] {
            for p in doc[sec] as! [[String: String]] {
                checks += 2
                let n = g.normalize(p["text"]!)
                if !n.unicodeScalars.elementsEqual(p["normalized"]!.unicodeScalars) {
                    misses.append("\(sec)-normalized \(p["id"]!) \(p["text"]!)\n  want \(p["normalized"]!)\n  got  \(n)")
                }
                let ph = g.phonemize(p["text"]!)
                if !ph.unicodeScalars.elementsEqual(p["leokani"]!.unicodeScalars) {
                    misses.append("\(sec) \(p["id"]!) \(p["text"]!)\n  want \(p["leokani"]!)\n  got  \(ph)")
                }
            }
        }
        if !misses.isEmpty {
            let report = misses.joined(separator: "\n")
            if let out = ProcessInfo.processInfo.environment["LEOKANI_GOLD_REPORT"] {
                try? report.write(toFile: out, atomically: true, encoding: .utf8)
            }
            XCTFail("\(misses.count) of \(checks) golden checks differ:\n" + misses.prefix(40).joined(separator: "\n"))
        }
        XCTAssertGreaterThanOrEqual(checks, 5000)   // 5078 on the internal goldens, 5022 on the public ones
    }

    func testEmptyInput() {
        XCTAssertEqual(Shared.g2p.phonemize(""), "")
        XCTAssertEqual(Shared.g2p.piece(""), "")
        XCTAssertEqual(Shared.g2p.phonemize("   ...  "), "")
    }

    func testBundledModelLoadsTheReleaseWeights() throws {
        for v in LeokaniG2P.Variant.allCases {
            let dir = try XCTUnwrap(LeokaniG2P.bundledModelDirectory(v))
            let sums = try String(contentsOf: dir.appendingPathComponent("SHA256SUMS"), encoding: .utf8)
            XCTAssertTrue(sums.contains("context.onnx"), v.rawValue)
        }
        XCTAssertEqual(Shared.g2p.variant, .micro)
        XCTAssertEqual(Shared.g2p.phonemeSymbols.count, 47)
    }
}
