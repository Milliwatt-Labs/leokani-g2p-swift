// SPDX-License-Identifier: MIT
// Leokani G2P by Milliwatt Labs (milliwattlabs.com)
//
// Reads the release .onnx files directly: the float32 initializers and, for each MatMul, which initializer it
// multiplies by (the exporter names those "onnx::MatMul_NNN", so the node's output name says what the weight is).
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
        var nodes: [(op: String, inputs: [String], outputs: [String])] = []
        while let (f, wt) = try g.key() {
            switch (f, wt) {
            case (1, 2): nodes.append(try node(try g.sub()))
            case (5, 2):
                let (name, t) = try tensor(try g.sub())
                tensors[name] = t
            default: try g.skip(wt)
            }
        }
        for n in nodes where n.op == "MatMul" && n.inputs.count == 2 {
            guard let wt = tensors[n.inputs[1]], let out = n.outputs.first else { continue }
            var key = out
            if key.hasPrefix("/") { key.removeFirst() }
            if key.hasSuffix("/MatMul_output_0") { key.removeLast("/MatMul_output_0".count) }
            matmul[key] = wt
        }
    }

    private func node(_ n0: PB) throws -> (op: String, inputs: [String], outputs: [String]) {
        var n = n0
        var op = "", ins: [String] = [], outs: [String] = []
        while let (f, wt) = try n.key() {
            switch (f, wt) {
            case (1, 2): ins.append(try n.string())
            case (2, 2): outs.append(try n.string())
            case (4, 2): op = try n.string()
            default: try n.skip(wt)
            }
        }
        return (op, ins, outs)
    }

    private func tensor(_ t0: PB) throws -> (String, Tensor) {
        var t = t0
        var dims: [Int] = [], type = 0, name = ""
        var floats: [Float] = []
        var raw: PB?
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
            case (8, 2): name = try t.string()
            case (9, 2): raw = try t.sub()
            default: try t.skip(wt)
            }
        }
        if type != 1 { return (name, Tensor(dims: dims, data: [])) }   // only float32 weights are used
        if let raw { floats = raw.floats() }
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
