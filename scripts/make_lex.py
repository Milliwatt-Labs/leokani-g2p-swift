#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""leokani-g2p.json(.gz) -> leokani-g2p.lex, the memory-mapped form LeokaniG2P(compactLexicon:) reads.

Layout (little-endian):
  "LKLX0001"                 magic
  u32 H, H bytes             the model document without "lexicon" (UTF-8 JSON)
  pad to 4
  u32 N                      entries, sorted by the key's UTF-8 bytes
  u32 off[N + 1]             entry i is blob[off[i]:off[i+1]]: key bytes, then value bytes
  u32 mid[N]                 value i starts at blob[mid[i]]
  blob
Python stdlib only: run with python3 -I make_lex.py IN OUT.
"""
import gzip, json, struct, sys

def main(src, dst):
    raw = gzip.open(src).read() if src.endswith(".gz") else open(src, "rb").read()
    doc = json.loads(raw)
    lex = doc.pop("lexicon")
    head = json.dumps(doc, ensure_ascii=False, separators=(",", ":")).encode()
    items = sorted(((k.encode(), v.encode()) for k, v in lex.items()), key=lambda kv: kv[0])
    off, mid, blob = [], [], bytearray()
    for k, v in items:
        off.append(len(blob)); blob += k
        mid.append(len(blob)); blob += v
    off.append(len(blob))
    out = bytearray(b"LKLX0001") + struct.pack("<I", len(head)) + head
    while len(out) % 4:
        out += b"\0"
    out += struct.pack("<I", len(items))
    out += struct.pack(f"<{len(off)}I", *off) + struct.pack(f"<{len(mid)}I", *mid) + blob
    tmp = dst + ".tmp"
    open(tmp, "wb").write(out)
    import os
    os.replace(tmp, dst)
    print(f"make_lex: {len(items)} entries, {len(out)} bytes -> {dst}")

if __name__ == "__main__":
    main(*sys.argv[1:3])
