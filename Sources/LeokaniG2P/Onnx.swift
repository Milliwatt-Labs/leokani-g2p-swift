// SPDX-License-Identifier: MIT
// Leokani G2P by Milliwatt Labs (milliwattlabs.com)
//
// Reads the release .onnx files directly: the float32 initializers and, for each MatMul, which initializer it
// multiplies by (the exporter names those "onnx::MatMul_NNN", so the node's output name says what the weight is).
// 1.3's graphs store their weights as signed bytes times one scale per channel (Cast + Mul) or float16 (Cast): those are
// expanded to float32 under the name the last node outputs, which is the 1.2 weight's name.
// Only what Leokani G2P's three graphs need; not a general ONNX runtime.
import Foundation

struct Tensor {
    let dims: [Int]
    let data: [Float]
}

struct OnnxWeights {
    var tensors: [String: Tensor] = [:]
    /// "enc_layers.0/att/q" -> the [in, out] weight of that MatMul
    var matmul: [String: Tensor] = [:]

    func t(_ name: String) throws -> Tensor {
        guard let x = tensors[name] else { throw G2PError("model: no tensor \(name)") }
        return x
    }
    func w(_ name: String) throws -> Tensor {
        guard let x = matmul[name] else { throw G2PError("model: no MatMul \(name)") }
        return x
    }

    init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            var model = PB(p, 0, p.count)
            while let (f, wt) = try model.key() {
                if f == 7, wt == 2 { try graph(try model.sub()) } else { try model.skip(wt) }
            }
        }
        if tensors.isEmpty { throw G2PError("model: \(url.lastPathComponent) has no weights") }
    }

    private mutating func graph(_ g0: PB) throws {
        var g = g0
        var nodes: [(op: String, inputs: [String], outputs: [String], axis: Int)] = []
        while let (f, wt) = try g.key() {
            switch (f, wt) {
            case (1, 2): nodes.append(try node(try g.sub()))
            case (5, 2):
                let (name, t) = try tensor(try g.sub())
                tensors[name] = t
            default: try g.skip(wt)
            }
        }
        // weights stored small: expand them first, so the MatMuls below find them under their own names.
        // 1.3: signed bytes or float16 -> Cast (read as float32 above), then bytes * per-channel scale -> Mul of two weights
        var uses: [String: Int] = [:]
        for n in nodes { for x in n.inputs { uses[x, default: 0] += 1 } }
        for n in nodes where n.op == "Cast" || n.op == "Mul" {
            guard let out = n.outputs.first, let a = tensors[n.inputs[0]], !a.data.isEmpty else { continue }
            if n.op == "Cast" {
                tensors[out] = a
                if uses[n.inputs[0]] == 1 { tensors[n.inputs[0]] = nil }
                continue
            }
            guard n.inputs.count == 2, let b = tensors[n.inputs[1]], !b.data.isEmpty,
                  let m = broadcastMul(a, b) ?? broadcastMul(b, a) else { continue }
            tensors[out] = m
            for x in n.inputs where uses[x] == 1 { tensors[x] = nil }
        }
        for n in nodes where n.op == "MatMul" && n.inputs.count == 2 {
            guard let wt = tensors[n.inputs[1]], let out = n.outputs.first else { continue }
            var key = out
            if key.hasPrefix("/") { key.removeFirst() }
            if key.hasSuffix("/MatMul_output_0") { key.removeLast("/MatMul_output_0".count) }
            matmul[key] = wt
        }
    }

    /// a * b, b broadcast into a's shape (numpy rules, b's dims right-aligned); nil if it doesn't broadcast
    private func broadcastMul(_ a: Tensor, _ b: Tensor) -> Tensor? {
        let r = a.dims.count
        guard b.dims.count <= r else { return nil }
        let bd = [Int](repeating: 1, count: r - b.dims.count) + b.dims
        for k in 0..<r where bd[k] != 1 && bd[k] != a.dims[k] { return nil }
        var st = [Int](repeating: 0, count: r), acc = 1
        for k in stride(from: r - 1, through: 0, by: -1) {
            st[k] = bd[k] == 1 ? 0 : acc
            acc *= bd[k]
        }
        var out = [Float](repeating: 0, count: a.data.count)
        var idx = [Int](repeating: 0, count: r)
        for i in 0..<a.data.count {
            var j = 0
            for k in 0..<r { j += idx[k] * st[k] }
            out[i] = a.data[i] * b.data[j]
            var k = r - 1
            while k >= 0 {
                idx[k] += 1
                if idx[k] < a.dims[k] { break }
                idx[k] = 0
                k -= 1
            }
        }
        return Tensor(dims: a.dims, data: out)
    }

    private func node(_ n0: PB) throws -> (op: String, inputs: [String], outputs: [String], axis: Int) {
        var n = n0
        var op = "", ins: [String] = [], outs: [String] = [], axis = 1
        while let (f, wt) = try n.key() {
            switch (f, wt) {
            case (1, 2): ins.append(try n.string())
            case (2, 2): outs.append(try n.string())
            case (4, 2): op = try n.string()
            case (5, 2):                                       // an attribute: only an axis is read
                var a = try n.sub()
                var name = "", i = 0
                while let (af, awt) = try a.key() {
                    switch (af, awt) {
                    case (1, 2): name = try a.string()
                    case (3, 0): i = Int(Int64(bitPattern: try a.varint()))
                    default: try a.skip(awt)
                    }
                }
                if name == "axis" { axis = i }
            default: try n.skip(wt)
            }
        }
        return (op, ins, outs, axis)
    }

    private func tensor(_ t0: PB) throws -> (String, Tensor) {
        var t = t0
        var dims: [Int] = [], type = 0, name = ""
        var floats: [Float] = []
        var raw: PB?
        var i32: [Int64]?
        while let (f, wt) = try t.key() {
            switch (f, wt) {
            case (1, 0): dims.append(Int(try t.varint()))
            case (1, 2):
                var d = try t.sub()
                while !d.atEnd { dims.append(Int(try d.varint())) }
            case (2, 0): type = Int(try t.varint())
            case (4, 2):
                let d = try t.sub()
                floats = d.floats()
            case (4, 5): floats.append(try t.fixed32Float())
            case (5, 0): i32 = (i32 ?? []) + [Int64(bitPattern: try t.varint())]
            case (5, 2):
                var d = try t.sub()
                var v: [Int64] = []
                while !d.atEnd { v.append(Int64(bitPattern: try d.varint())) }
                i32 = (i32 ?? []) + v
            case (8, 2): name = try t.string()
            case (9, 2): raw = try t.sub()
            default: try t.skip(wt)
            }
        }
        switch type {
        case 1: if let raw { floats = raw.floats() }
        case 3:                                                  // signed bytes (1.3's weights, before their scale)
            if let raw { floats = raw.signedBytes() } else if let i32 { floats = i32.map { Float(((Int($0) & 0xFF) ^ 0x80) - 0x80) } }
        case 10:                                                 // float16 (Cast's input)
            if let raw { floats = raw.halfs() } else if let i32 { floats = i32.map { halfToFloat(UInt16(truncatingIfNeeded: $0)) } }
        default: return (name, Tensor(dims: dims, data: []))     // only float weights are used
        }
        let n = dims.reduce(1, *)
        guard floats.count == n else { throw G2PError("model: tensor \(name) has \(floats.count) values, not \(n)") }
        return (name, Tensor(dims: dims, data: floats))
    }
}

/// a protobuf wire-format cursor over a byte range
private struct PB {
    let p: UnsafeBufferPointer<UInt8>
    var i: Int
    let end: Int
    init(_ p: UnsafeBufferPointer<UInt8>, _ i: Int, _ end: Int) { self.p = p; self.i = i; self.end = end }
    var atEnd: Bool { i >= end }

    mutating func varint() throws -> UInt64 {
        var v: UInt64 = 0, s: UInt64 = 0
        while true {
            guard i < end, s < 64 else { throw G2PError("model: bad protobuf") }
            let b = p[i]; i += 1
            v |= UInt64(b & 0x7F) << s
            if b & 0x80 == 0 { return v }
            s += 7
        }
    }
    mutating func key() throws -> (Int, Int)? {
        if atEnd { return nil }
        let k = try varint()
        return (Int(k >> 3), Int(k & 7))
    }
    mutating func sub() throws -> PB {
        let n = Int(try varint())
        guard n >= 0, i + n <= end else { throw G2PError("model: bad protobuf length") }
        let s = PB(p, i, i + n)
        i += n
        return s
    }
    mutating func string() throws -> String {
        let s = try sub()
        return String(decoding: UnsafeBufferPointer(rebasing: p[s.i..<s.end]), as: UTF8.self)
    }
    mutating func fixed32Float() throws -> Float {
        guard i + 4 <= end else { throw G2PError("model: bad protobuf") }
        var u: UInt32 = 0
        for k in 0..<4 { u |= UInt32(p[i + k]) << (8 * k) }
        i += 4
        return Float(bitPattern: u)
    }
    func floats() -> [Float] {
        let n = (end - i) / 4
        var out = [Float](repeating: 0, count: n)
        out.withUnsafeMutableBytes { dst in
            dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(p)[i..<(i + n * 4)]))
        }
        // ONNX raw data is little-endian, as every Apple and Android CPU is
        return out
    }
    func signedBytes() -> [Float] {                       // two's complement bytes -> -128...127
        (i..<end).map { Float((Int(p[$0]) ^ 0x80) - 0x80) }
    }
    func halfs() -> [Float] {
        stride(from: i, to: end - 1, by: 2).map { halfToFloat(UInt16(p[$0]) | UInt16(p[$0 + 1]) << 8) }
    }
    mutating func skip(_ wt: Int) throws {
        switch wt {
        case 0: _ = try varint()
        case 1: i += 8
        case 2: _ = try sub()
        case 5: i += 4
        default: throw G2PError("model: protobuf wire type \(wt)")
        }
        if i > end { throw G2PError("model: bad protobuf") }
    }
}

/// IEEE 754 binary16 -> Float (no Float16 type on every platform this builds for)
func halfToFloat(_ h: UInt16) -> Float {
    let sign = UInt32(h >> 15) << 31
    let e = Int((h >> 10) & 0x1F), m = UInt32(h & 0x3FF)
    if e == 0 {
        if m == 0 { return Float(bitPattern: sign) }
        return (sign != 0 ? -1 : 1) * Float(m) * 0x1p-24        // subnormal
    }
    if e == 31 { return Float(bitPattern: sign | 0x7F80_0000 | (m << 13)) }
    return Float(bitPattern: sign | UInt32(e - 15 + 127) << 23 | (m << 13))
}
