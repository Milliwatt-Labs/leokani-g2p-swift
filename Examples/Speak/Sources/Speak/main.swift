// SPDX-License-Identifier: MIT
// swift run -c release   (from Examples/Speak)
import Foundation
import LeokaniG2P

let g2p = try LeokaniG2P()

// Custom pronunciations: from a file, or one at a time.
if let names = Bundle.module.url(forResource: "names", withExtension: "tsv") {
    try g2p.userLexicon.load(contentsOf: names)
}
try g2p.userLexicon.add("Okafor", phonemes: "əkˈɑfɔɹ")

let lines = [
    "Dr. Okafor lands at 7:45 AM.",
    "Siobhan's flight costs $412.50.",
    "Nguyen and Leokani read the report.",
]
for line in lines {
    print(line)
    for chunk in g2p.phonemizeChunks(line) { print("  " + chunk) }
}
