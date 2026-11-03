#!/bin/bash
# Copies the release model files into the package resources and the goldens into the tests, for both variants:
# micro (the default) into Resources/model, mini into Resources/model/mini.
# Usage: scripts/sync-model.sh <model-dir>   (a Leokani G2P release folder, such as a download of
# huggingface.co/milliwattlabs/leokani-g2p; mini is read from its mini/ subfolder)
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
src="${1:?usage: scripts/sync-model.sh <model-dir>}"
dst="$here/Sources/LeokaniG2P/Resources/model"
fix="$here/Tests/LeokaniG2PTests/Fixtures"
mkdir -p "$dst/mini" "$fix"
for v in micro mini; do
  if [ $v = micro ]; then s="$src" d="$dst" gold=goldens.json; else s="$src/$v" d="$dst/$v" gold=goldens-$v.json; fi
  for f in leokani-g2p.json.gz oov-encoder.onnx oov-decoder.onnx context.onnx; do
    cp "$s/$f" "$d/$f"
  done
  cp "$s/goldens.json" "$fix/$gold"
  ( cd "$d" && shasum -a 256 leokani-g2p.json.gz oov-encoder.onnx oov-decoder.onnx context.onnx > SHA256SUMS )
  echo "== $v"; cat "$d/SHA256SUMS"
done
[ -f "$src/user-lexicon-goldens.json" ] && cp "$src/user-lexicon-goldens.json" "$fix/user-lexicon-goldens.json"
cp "$src/LICENSE" "$here/LICENSE"; cp "$src/LICENSE-CC-BY-4.0.txt" "$here/LICENSE-CC-BY-4.0.txt"; cp "$src/NOTICE" "$here/NOTICE"
