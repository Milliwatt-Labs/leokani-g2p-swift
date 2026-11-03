// SPDX-License-Identifier: MIT
// Leokani G2P by Milliwatt Labs (milliwattlabs.com)
//
// The three small networks, run in float32 on the CPU with the weights read from the release .onnx files:
//   oov-encoder + oov-decoder: a pre-norm transformer (3 + 3 layers, width 160, 4 heads), greedy decoding
//   context: embeddings -> a dilated 1-D conv stack -> per word, a form logit row and a join logit pair
// The operations and their order follow the exported graphs (scores = q·k, then * 1/sqrt(40), then the mask).
import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// c[m×n] = a[m×k] · b[k×n] (row-major), plus bias[n] when given
@inline(__always)
func gemm(_ a: [Float], _ m: Int, _ k: Int, _ b: [Float], _ n: Int, bias: [Float]? = nil) -> [Float] {
    var c = [Float](repeating: 0, count: m * n)
    #if canImport(Accelerate)
    a.withUnsafeBufferPointer { pa in
        b.withUnsafeBufferPointer { pb in
            c.withUnsafeMutableBufferPointer { pc in
                cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(m), Int32(n), Int32(k), 1,
                            pa.baseAddress, Int32(k), pb.baseAddress, Int32(n), 0, pc.baseAddress, Int32(n))
            }
        }
    }
    #else
    for i in 0..<m {
        for p in 0..<k {
            let av = a[i * k + p]
            if av == 0 { continue }
            for j in 0..<n { c[i * n + j] += av * b[p * n + j] }
        }
    }
    #endif
    if let bias {
        for i in 0..<m { for j in 0..<n { c[i * n + j] = bias[j] + c[i * n + j] } }
    }
    return c
}

@inline(__always)
func layerNorm(_ x: [Float], _ rows: Int, _ d: Int, _ w: [Float], _ b: [Float], eps: Float = 1e-5) -> [Float] {
    var y = [Float](repeating: 0, count: rows * d)
    for r in 0..<rows {
        let o = r * d
        var mean: Float = 0
        for j in 0..<d { mean += x[o + j] }
        mean /= Float(d)
        var v: Float = 0
        for j in 0..<d { let t = x[o + j] - mean; v += t * t }
        v /= Float(d)
        let inv = 1 / (v + eps).squareRoot()
        for j in 0..<d { y[o + j] = (x[o + j] - mean) * inv * w[j] + b[j] }
    }
    return y
}

private struct Linear {
    let w: [Float], b: [Float], inD: Int, outD: Int
    init(_ m: OnnxWeights, _ key: String, _ bias: String) throws {
        let t = try m.w(key)
        w = t.data; inD = t.dims[0]; outD = t.dims[1]
        b = try m.t(bias).data
    }
    func callAsFunction(_ x: [Float], _ rows: Int) -> [Float] { gemm(x, rows, inD, w, outD, bias: b) }
}

private struct Norm {
    let w: [Float], b: [Float]
    init(_ m: OnnxWeights, _ p: String) throws { w = try m.t(p + ".weight").data; b = try m.t(p + ".bias").data }
    func callAsFunction(_ x: [Float], _ rows: Int) -> [Float] { layerNorm(x, rows, w.count, w, b) }
}

private let D = 160, HEADS = 4, DH = 40
private let SCALE = Float(0.15811388194561005)

/// softmax(q·k * scale) · v for one query row against keys/values [n×D], one head slice
@inline(__always)
private func attend(_ q: [Float], _ qo: Int, _ k: [Float], _ v: [Float], _ n: Int, _ out: inout [Float], _ oo: Int) {
    var s = [Float](repeating: 0, count: n)
    for h in 0..<HEADS {
        let ho = h * DH
        var mx = -Float.infinity
        for j in 0..<n {
            var dot: Float = 0
            let ko = j * D + ho
            for e in 0..<DH { dot += q[qo + ho + e] * k[ko + e] }
            s[j] = dot * SCALE
            if s[j] > mx { mx = s[j] }
        }
        var sum: Float = 0
        for j in 0..<n { s[j] = expf(s[j] - mx); sum += s[j] }
        for e in 0..<DH {
            var acc: Float = 0
            for j in 0..<n { acc += s[j] / sum * v[j * D + ho + e] }
            out[oo + ho + e] = acc
        }
    }
}

final class OOVModel {
    private struct EncLayer { let n1, n2: Norm; let q, k, v, o, a, b: Linear }
    private struct DecLayer { let n1, n2, n3: Norm; let q, k, v, o, cq, ck, cv, co, a, b: Linear }
    private let src: [Float], posS: [Float], tgt: [Float], posT: [Float]
    private let enc: [EncLayer], dec: [DecLayer]
    private let encNorm: Norm, norm: Norm, head: Linear
    let maxIn: Int, maxOutPositions: Int, vocab: Int

    init(encoder: URL, decoder: URL) throws {
        let e = try OnnxWeights(contentsOf: encoder)
        let d = try OnnxWeights(contentsOf: decoder)
        src = try e.t("m.src.weight").data
        let ps = try e.t("m.pos_s.weight")
        posS = ps.data; maxIn = ps.dims[0]
        tgt = try d.t("m.tgt.weight").data
        vocab = try d.t("m.tgt.weight").dims[0]
        let pt = try d.t("m.pos_t.weight")
        posT = pt.data; maxOutPositions = pt.dims[0]
        var el: [EncLayer] = []
        var i = 0
        while e.tensors["m.enc_layers.\(i).n1.weight"] != nil {
            let p = "enc_layers.\(i)", b = "m.enc_layers.\(i)"
            el.append(EncLayer(n1: try Norm(e, b + ".n1"), n2: try Norm(e, b + ".n2"),
                               q: try Linear(e, p + "/att/q", b + ".att.q.bias"), k: try Linear(e, p + "/att/k", b + ".att.k.bias"),
                               v: try Linear(e, p + "/att/v", b + ".att.v.bias"), o: try Linear(e, p + "/att/o", b + ".att.o.bias"),
                               a: try Linear(e, p + "/ff/a", b + ".ff.a.bias"), b: try Linear(e, p + "/ff/b", b + ".ff.b.bias")))
            i += 1
        }
        var dl: [DecLayer] = []
        i = 0
        while d.tensors["m.dec_layers.\(i).n1.weight"] != nil {
            let p = "dec_layers.\(i)", b = "m.dec_layers.\(i)"
            dl.append(DecLayer(n1: try Norm(d, b + ".n1"), n2: try Norm(d, b + ".n2"), n3: try Norm(d, b + ".n3"),
                               q: try Linear(d, p + "/att/q", b + ".att.q.bias"), k: try Linear(d, p + "/att/k", b + ".att.k.bias"),
                               v: try Linear(d, p + "/att/v", b + ".att.v.bias"), o: try Linear(d, p + "/att/o", b + ".att.o.bias"),
                               cq: try Linear(d, p + "/cross/q", b + ".cross.q.bias"), ck: try Linear(d, p + "/cross/k", b + ".cross.k.bias"),
                               cv: try Linear(d, p + "/cross/v", b + ".cross.v.bias"), co: try Linear(d, p + "/cross/o", b + ".cross.o.bias"),
                               a: try Linear(d, p + "/ff/a", b + ".ff.a.bias"), b: try Linear(d, p + "/ff/b", b + ".ff.b.bias")))
            i += 1
        }
        guard !el.isEmpty, !dl.isEmpty else { throw G2PError("model: no transformer layers") }
        enc = el; dec = dl
        encNorm = try Norm(e, "m.enc_norm"); norm = try Norm(d, "m.norm")
        head = try Linear(d, "head", "m.head.bias")
    }

    private func selfAttention(_ h: [Float], _ n: Int, _ L: EncLayer) -> [Float] {
        let q = L.q(h, n), k = L.k(h, n), v = L.v(h, n)
        var a = [Float](repeating: 0, count: n * D)
        for r in 0..<n { attend(q, r * D, k, v, n, &a, r * D) }
        return L.o(a, n)
    }

    /// ids: [bos] + chars + [eos]; -> memory [n×D]
    func encode(_ ids: [Int]) -> [Float] {
        let n = ids.count
        var x = [Float](repeating: 0, count: n * D)
        for t in 0..<n { for j in 0..<D { x[t * D + j] = src[ids[t] * D + j] + posS[t * D + j] } }
        for L in enc {
            let a = selfAttention(L.n1(x, n), n, L)
            for j in 0..<(n * D) { x[j] += a[j] }
            let f = L.b(L.a(L.n2(x, n), n).map { max($0, 0) }, n)
            for j in 0..<(n * D) { x[j] += f[j] }
        }
        return encNorm(x, n)
    }

    /// greedy decoding, the reference's loop for one word: token ids until eos (1) or pad (0), at most maxOut steps
    func decode(memory: [Float], n: Int, maxOut: Int) -> [Int] {
        let cross = dec.map { (L: DecLayer) in (L.ck(memory, n), L.cv(memory, n)) }
        var keys = [[Float]](repeating: [], count: dec.count)
        var vals = [[Float]](repeating: [], count: dec.count)
        var out: [Int] = []
        var prev = 2                                           // BOS
        for t in 0..<min(maxOut, maxOutPositions) {
            var x = [Float](repeating: 0, count: D)
            for j in 0..<D { x[j] = tgt[prev * D + j] + posT[t * D + j] }
            for (li, L) in dec.enumerated() {
                let h = L.n1(x, 1)
                let q = L.q(h, 1)
                keys[li] += L.k(h, 1)
                vals[li] += L.v(h, 1)
                var a = [Float](repeating: 0, count: D)
                attend(q, 0, keys[li], vals[li], t + 1, &a, 0)
                let o = L.o(a, 1)
                for j in 0..<D { x[j] += o[j] }
                let cq = L.cq(L.n2(x, 1), 1)
                var c = [Float](repeating: 0, count: D)
                attend(cq, 0, cross[li].0, cross[li].1, n, &c, 0)
                let co = L.co(c, 1)
                for j in 0..<D { x[j] += co[j] }
                let f = L.b(L.a(L.n3(x, 1), 1).map { max($0, 0) }, 1)
                for j in 0..<D { x[j] += f[j] }
            }
            let logits = head(norm(x, 1), 1)
            var best = 0
            for j in 1..<logits.count where logits[j] > logits[best] { best = j }   // first maximum, as argmax
            if best <= 1 { break }
            out.append(best)
            prev = best
        }
        return out
    }
}

final class ContextModel {
    private let embs: [(table: [Float], dim: Int)]
    private let inp: Linear, form: Linear, join: Linear
    private struct Conv { let taps: [[Float]]; let b: [Float]; let dil: Int }   // taps[k]: [in×out]
    private let convs: [Conv]
    let width: Int

    init(url: URL) throws {
        let m = try OnnxWeights(contentsOf: url)
        var e: [([Float], Int)] = []
        var i = 0
        while let t = m.tensors["embs.\(i).weight"] { e.append((t.data, t.dims[1])); i += 1 }
        embs = e
        inp = try Linear(m, "inp", "inp.bias")
        form = try Linear(m, "form", "form.bias")
        join = try Linear(m, "join", "join.bias")
        width = inp.outD
        var cs: [Conv] = []
        i = 0
        while let t = m.tensors["convs.\(i).weight"] {
            let (o, inC, k) = (t.dims[0], t.dims[1], t.dims[2])
            var taps: [[Float]] = []
            for kk in 0..<k {
                var w = [Float](repeating: 0, count: inC * o)
                for oc in 0..<o { for ic in 0..<inC { w[ic * o + oc] = t.data[(oc * inC + ic) * k + kk] } }
                taps.append(w)
            }
            // the exported stack: k=3 convs at dilation 1, 2, 4, 1 (pads = dilation), each followed by a k=1 conv
            let dil = k == 1 ? 1 : [1, 2, 4, 1][min(i / 2, 3)]
            cs.append(Conv(taps: taps, b: try m.t("convs.\(i).bias").data, dil: dil))
            i += 1
        }
        convs = cs
        guard embs.count == 14, convs.count % 2 == 0, !convs.isEmpty else { throw G2PError("model: unexpected context graph") }
    }

    private func conv(_ x: [Float], _ n: Int, _ c: Conv) -> [Float] {
        let C = width
        var y = [Float](repeating: 0, count: n * C)
        for t in 0..<n { for j in 0..<C { y[t * C + j] = 0 } }
        let k = c.taps.count
        for kk in 0..<k {
            let off = (kk - (k - 1) / 2) * c.dil
            // rows t whose source t+off is inside the piece
            let lo = max(0, -off), hi = min(n, n - off)
            if lo >= hi { continue }
            let rows = hi - lo
            let src = Array(x[((lo + off) * C)..<((hi + off) * C)])
            let part = gemm(src, rows, C, c.taps[kk], C)
            for r in 0..<rows { for j in 0..<C { y[(lo + r) * C + j] += part[r * C + j] } }
        }
        for t in 0..<n { for j in 0..<C { y[t * C + j] += c.b[j] } }
        return y
    }

    /// features [n×14] -> (form [n×52], join [n×2])
    func run(_ feats: [[Int]]) -> (form: [[Float]], join: [[Float]]) {
        let n = feats.count
        let inD = embs.reduce(0) { $0 + $1.dim }
        var e = [Float](repeating: 0, count: n * inD)
        for t in 0..<n {
            var o = t * inD
            for (f, emb) in embs.enumerated() {
                let id = feats[t][f]
                for j in 0..<emb.dim { e[o + j] = emb.table[id * emb.dim + j] }
                o += emb.dim
            }
        }
        let C = width
        var x = inp(e, n)
        for t in 0..<n where !(feats[t][0] > 0) { for j in 0..<C { x[t * C + j] = 0 } }   // * mask
        var ci = 0
        while ci < convs.count {
            let a = conv(x.map { max($0, 0) }, n, convs[ci])
            var b = conv(a.map { max($0, 0) }, n, convs[ci + 1])
            for t in 0..<n where !(feats[t][0] > 0) { for j in 0..<C { b[t * C + j] = 0 } }
            for j in 0..<(n * C) { x[j] += b[j] }
            ci += 2
        }
        let r = x.map { max($0, 0) }
        let f = form(r, n), jn = join(r, n)
        let fo = form.outD, jo = join.outD
        return ((0..<n).map { Array(f[($0 * fo)..<(($0 + 1) * fo)]) }, (0..<n).map { Array(jn[($0 * jo)..<(($0 + 1) * jo)]) })
    }
}
