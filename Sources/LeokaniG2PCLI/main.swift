// SPDX-License-Identifier: MIT
// leokani-g2p: English text to Kokoro-style phonemes (Leokani G2P for Swift).
//   leokani-g2p "the wind was cold"              one piece (no punctuation)
//   leokani-g2p --text "Hello there, Sam."       a whole line
//   leokani-g2p --lexicon names.tsv --text ...    custom pronunciations (.json or .tsv), repeatable
//   echo "a piece" | leokani-g2p                 pieces from stdin, one per line
//   leokani-g2p --variant mini --text ...         the larger model (default micro)
import Foundation
import LeokaniG2P

var args = Array(CommandLine.arguments.dropFirst())
var text: String?, model: URL?, lexicons: [URL] = [], pieceArg: String?, variant = LeokaniG2P.Variant.micro
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--text": text = args.isEmpty ? "" : args.removeFirst()
    case "--model": model = URL(fileURLWithPath: args.removeFirst())
    case "--lexicon": lexicons.append(URL(fileURLWithPath: args.removeFirst()))
    case "--variant":
        let v = args.isEmpty ? "" : args.removeFirst()
        guard let parsed = LeokaniG2P.Variant(rawValue: v) else {
            FileHandle.standardError.write(Data("leokani-g2p: --variant is micro or mini, not \(v)\n".utf8))
            exit(2)
        }
        variant = parsed
    case "-h", "--help":
        print("usage: leokani-g2p [--model DIR] [--variant micro|mini] [--lexicon FILE]... [--text LINE | PIECE]")
        exit(0)
    default: pieceArg = a
    }
}
do {
    let g = try LeokaniG2P(modelDirectory: model, variant: variant)
    for l in lexicons { try g.loadUserLexicon(contentsOf: l) }
    if let text { print(g.phonemize(text)); exit(0) }
    if let pieceArg { print(g.piece(pieceArg)); exit(0) }
    while let ln = readLine() { print(g.piece(ln)) }
} catch {
    FileHandle.standardError.write(Data("leokani-g2p: \(error.localizedDescription)\n".utf8))
    exit(1)
}
