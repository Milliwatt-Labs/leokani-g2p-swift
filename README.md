# Leokani G2P for Swift

English text to Kokoro-style phonemes, on iOS and macOS, without espeak-ng.

Leokani G2P is a small, fast English phonemizer from [Milliwatt Labs](https://milliwattlabs.com). It produces espeak compatible phoneme codes, made from the ground up: the same Kokoro/misaki-style codes
Leokani-tts and Kokoro use. It contains no espeak-ng code or data files.

This package is a pure-Swift port of the [Python package](https://github.com/Milliwatt-Labs/leokani-g2p). It
reproduces every output in `goldens.json` exactly, has no dependencies beyond Apple's Accelerate framework, and
ships the same model files inside the package, in two sizes: `.micro` (the default, about 19 MB) and `.mini`
(about 22 MB, better on names and rare words).

## Install

Swift Package Manager, iOS 16 / macOS 13 or newer:

```swift
dependencies: [
    .package(url: "https://github.com/Milliwatt-Labs/leokani-g2p-swift", from: "1.2.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "LeokaniG2P", package: "leokani-g2p-swift")]),
]
```

In Xcode: File → Add Package Dependencies…, then add the `LeokaniG2P` library to your app target.

## Quick start

```swift
import LeokaniG2P

let g2p = try LeokaniG2P()          // load once and reuse; safe to call from any thread
let mini = try LeokaniG2P(variant: .mini)   // the larger model

g2p.phonemize("Dr. Okafor lands at 7:45 AM.")
// "dˈɑktəɹ ˈɑkæfəɹ lˈændz æt sˈɛvən fˈɔɹɾi fˈIv ˌAˈɛm."

g2p.phonemizeChunks("A long paragraph. Of several clauses.")
// ["ə lˈɔŋ pˈæɹəɡɹˌæf.", "ʌv sˈɛvɹᵊl klˈɔzᵻz."]

g2p.piece("the wind was cold")      // one clause with no punctuation, no chunking
g2p.normalize("It costs $4.99.")    // the text as it will be read, before phonemes
```

Loading takes a moment (the lexicon has about 570,000 entries), so create the instance off the main thread at
startup and keep it. Kokoro takes up to 510 phoneme characters at a time, so pass it one chunk at a time.

## Custom pronunciations

Brands, people and places can be given their own pronunciation. Entries are checked before the lexicon.

```swift
try g2p.userLexicon.add("Siobhan", say: "shivawn")            // a respelling, read as written text
try g2p.userLexicon.add("Leokani", phonemes: "lˌAOkˈɑni")      // phonemes, in the output's own symbols
try g2p.userLexicon.add("Nguyen", "win")                       // "/.../" is phonemes, anything else a respelling
try g2p.loadUserLexicon(contentsOf: namesURL)                   // a .json or .tsv file

g2p.phonemize("Siobhan's car.")   // the possessive follows the entry: "ʃˈɪvɔnz kˈɑɹ."
```

Rules, the same in every Leokani G2P port:

- A key with no capital letter matches any casing; a key with a capital matches only that casing, and wins.
- `Leokani's` falls back to `Leokani`: phonemes get `ᵻz`, `s` or `z`; a respelling gets `'s`.
- Phonemes may use `g2p.phonemeSymbols`, `ˈ`, `ˌ` and spaces; anything else is rejected.
- Later entries replace earlier ones with the same key. `userLexicon.removeAll()` clears them.

TSV, one entry per line (blank lines and `#` comments are skipped):

```tsv
# key<TAB>value
Siobhan	shivawn
Leokani	/lˌAOkˈɑni/
```

JSON:

```json
{
  "format": "leokani-g2p-user/1",
  "words": {
    "Siobhan": "shivawn",
    "Leokani": {"phonemes": "lˌAOkˈɑni"},
    "Nguyen": {"say": "win"}
  }
}
```

## Command line (macOS)

```bash
swift run -c release leokani-g2p --text "Hello there, Sam."
swift run -c release leokani-g2p --lexicon names.tsv --text "Siobhan is here."
echo "the wind was cold" | swift run -c release leokani-g2p
```

[Examples/Speak](Examples/Speak) is a small program that uses the library with a custom pronunciation file:
`cd Examples/Speak && swift run -c release`.

## Tests

```bash
swift test -c release
```

The tests check every entry in `goldens.json` and the shared custom-pronunciation vectors in
`user-lexicon-goldens.json`. They also run on an iOS simulator:
`xcodebuild test -scheme LeokaniG2P-Package -destination 'platform=iOS Simulator,name=iPhone 17'`.

## Updating the model files

`scripts/sync-model.sh <model-dir>` copies a release's model files (for example a download of
[milliwattlabs/leokani-g2p](https://huggingface.co/milliwattlabs/leokani-g2p)) into `Sources/LeokaniG2P/Resources/model`,
its goldens into the tests, and writes `SHA256SUMS`. Run the tests afterwards.

## Limits

- American English only.
- Output is Kokoro/misaki-style phonemes, not espeak-ng's own IPA, and there is no audio: it is the text front
  end only.
- Unusual names and rare words outside the lexicon can be misread; use custom pronunciations for the ones that
  matter to you.
- Heteronyms ("read", "lead", "wind", "lives") are picked from nearby words, and the guess can be wrong.

## License

- Code (the `LeokaniG2P` library, the `leokani-g2p` tool, tests and examples): [MIT](LICENSE).
- Model weights (`*.onnx`), the lexicon (`leokani-g2p.json.gz`) and the goldens: [CC BY 4.0](LICENSE-CC-BY-4.0.txt).

Credit it as: **Leokani G2P by Milliwatt Labs (milliwattlabs.com)**. The lexicon's word list includes words from the
[CMU Pronouncing Dictionary](https://github.com/cmusphinx/cmudict) (BSD-2-Clause) and place names from
[GeoNames](https://www.geonames.org) (CC BY 4.0). See [NOTICE](NOTICE) for every credit.
