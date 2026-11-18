import Foundation
import Testing

@testable import MLXLMCommon

/// Tests for rearranging a weights file in place so its large tensors start on page
/// boundaries. No model and no GPU: the files are written here.
@Suite(.serialized)
struct AlignedWeightsTests {

    private struct Tensor {
        var name: String
        var dtype = "U8"
        var bytes: Data
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aligned-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Bytes that differ from tensor to tensor and along each one, so a move to the wrong place shows.
    private func pattern(_ seed: Int, count: Int) -> Data {
        Data((0 ..< count).map { UInt8(truncatingIfNeeded: ($0 &* 31 &+ seed &* 97) ^ ($0 >> 8)) })
    }

    /// Small and large tensors turn about, as in a quantized model: weights, then their scales.
    private var tensors: [Tensor] {
        [
            Tensor(name: "layers.0.weight", bytes: pattern(1, count: 200_000)),
            Tensor(name: "layers.0.scales", bytes: pattern(2, count: 3_001)),
            Tensor(name: "layers.1.weight", bytes: pattern(3, count: 70_000)),
            Tensor(name: "norm/weight \"odd\" name", bytes: pattern(4, count: 17)),
            Tensor(name: "empty", bytes: Data()),
            Tensor(name: "layers.2.weight", bytes: pattern(5, count: 131_072)),
            Tensor(name: "tail", bytes: pattern(6, count: 5)),
        ]
    }

    /// A safetensors file with its tensors end to end, as a library writes one.
    @discardableResult
    private func write(_ tensors: [Tensor], to url: URL, metadata: [String: String] = ["format": "mlx"], extra: Int = 0) throws -> Int {
        var entries: [String: Any] = ["__metadata__": metadata]
        var offset = 0
        var body = Data()
        for tensor in tensors {
            entries[tensor.name] = ["dtype": tensor.dtype, "shape": [tensor.bytes.count], "data_offsets": [offset, offset + tensor.bytes.count]]
            offset += tensor.bytes.count
            body.append(tensor.bytes)
        }
        let header = try JSONSerialization.data(withJSONObject: entries)
        var data = Data((0 ..< 8).map { UInt8(truncatingIfNeeded: header.count >> (8 * $0)) })
        data.append(header)
        data.append(body)
        data.append(Data(repeating: 0xEE, count: extra))
        try data.write(to: url)
        return data.count
    }

    /// Every tensor of the file by name, read through its header.
    private func read(_ url: URL) throws -> (header: AlignedWeights.Header, tensors: [String: Data]) {
        let descriptor = open(url.path, O_RDONLY)
        defer { close(descriptor) }
        let header = try AlignedWeights.readHeader(descriptor)
        let data = try Data(contentsOf: url)
        var tensors: [String: Data] = [:]
        for entry in header.entries {
            tensors[entry.name] = data.subdata(in: (header.dataStart + entry.begin) ..< (header.dataStart + entry.end))
        }
        return (header, tensors)
    }

    private func expectRearranged(_ url: URL, from tensors: [Tensor], originalSize: Int) throws {
        let (header, found) = try read(url)
        #expect(found.count == tensors.count)
        for tensor in tensors { #expect(found[tensor.name] == tensor.bytes, "\(tensor.name) changed") }
        for entry in header.entries where entry.bytes >= 64 * 1024 {
            #expect((header.dataStart + entry.begin) % AlignedWeights.page == 0, "\(entry.name) is not on a page boundary")
        }
        #expect(header.metadata[AlignedWeights.sizeKey] == String(originalSize))
        #expect(header.metadata["format"] == "mlx")
        #expect(AlignedWeights.isAligned(url))
        #expect(!AlignedWeights.isPartWay(url))
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        #expect((size ?? 0) % AlignedWeights.page == 0)
        // What reads the start of the file to learn the size it was finds it there.
        let start = String(decoding: try Data(contentsOf: url).prefix(512).dropFirst(8), as: UTF8.self)
        #expect(start.contains("\"\(AlignedWeights.sizeKey)\":\"\(originalSize)\""))
    }

    @Test func `large tensors move to page boundaries and every byte is kept`() throws {
        let url = try folder().appendingPathComponent("model.safetensors")
        let size = try write(tensors, to: url)
        #expect(!AlignedWeights.isAligned(url))

        var reported: [Int] = []
        try AlignedWeights.align(url, chunk: 50_000) { reported.append($0) }

        try expectRearranged(url, from: tensors, originalSize: size)
        // Progress only goes up, and ends at all the tensors' bytes.
        #expect(reported == reported.sorted())
        #expect(reported.last == tensors.reduce(0) { $0 + $1.bytes.count })
    }

    @Test func `a file already rearranged is left as it is`() throws {
        let url = try folder().appendingPathComponent("model.safetensors")
        let size = try write(tensors, to: url)
        try AlignedWeights.align(url)
        let first = try Data(contentsOf: url)

        try AlignedWeights.align(url)

        #expect(try Data(contentsOf: url) == first)
        try expectRearranged(url, from: tensors, originalSize: size)
    }

    @Test func `cut short at any point, it carries on to the same file`() throws {
        let directory = try folder()
        let whole = directory.appendingPathComponent("whole.safetensors")
        let size = try write(tensors, to: whole)
        try AlignedWeights.align(whole, chunk: 50_000)
        let expected = try Data(contentsOf: whole)

        // 404,095 bytes of tensors in pieces of 50,000 at most: more stops than there are pieces.
        for stop in 1 ... 16 {
            let url = directory.appendingPathComponent("cut-\(stop).safetensors")
            try write(tensors, to: url)
            var interrupted = false
            do {
                try AlignedWeights.align(url, chunk: 50_000, stopAfter: stop)
            } catch AlignedWeights.Failure.interrupted {
                interrupted = true
                #expect(AlignedWeights.isPartWay(url))
                // The old file has given up what it moved, so the two never hold it twice.
                let left = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
                #expect((left ?? size) < size)
            }
            if interrupted {
                // Stopped again after one more piece (when any is left), then left to finish.
                try? AlignedWeights.align(url, chunk: 50_000, stopAfter: 1)
            }
            try AlignedWeights.align(url, chunk: 50_000)
            #expect(try Data(contentsOf: url) == expected, "stopped after \(stop) pieces")
        }
    }

    @Test func `a file that is not whole is left alone`() throws {
        let directory = try folder()
        // Something after the last tensor: not a file this was written for.
        let longer = directory.appendingPathComponent("longer.safetensors")
        try write(tensors, to: longer, extra: 10)
        let before = try Data(contentsOf: longer)
        #expect(throws: AlignedWeights.Failure.self) { try AlignedWeights.align(longer) }
        #expect(try Data(contentsOf: longer) == before)
        #expect(!AlignedWeights.isPartWay(longer))

        // A download that stopped early.
        let shorter = directory.appendingPathComponent("shorter.safetensors")
        try write(tensors, to: shorter)
        let cut = try Data(contentsOf: shorter).dropLast(1000)
        try cut.write(to: shorter)
        #expect(throws: AlignedWeights.Failure.self) { try AlignedWeights.align(shorter) }
        #expect(try Data(contentsOf: shorter) == cut)

        // Not a safetensors file at all.
        let other = directory.appendingPathComponent("other.safetensors")
        try Data(repeating: 9, count: 5000).write(to: other)
        #expect(throws: AlignedWeights.Failure.self) { try AlignedWeights.align(other) }
        #expect(try Data(contentsOf: other) == Data(repeating: 9, count: 5000))
    }

    @Test func `preparing a file to load finishes what was cut short and removes old copies`() throws {
        let directory = try folder()
        let url = directory.appendingPathComponent("model.safetensors")
        let size = try write(tensors, to: url)
        let untouched = try Data(contentsOf: url)
        try Data(repeating: 1, count: 100).write(to: url.appendingPathExtension("paged"))
        try Data(repeating: 1, count: 100).write(to: url.appendingPathExtension("paged-partial"))
        let wasOn = WeightMapping.isOn
        defer { WeightMapping.isOn = wasOn }

        // Mapping off: the file is not rearranged, the copies from an earlier version go.
        WeightMapping.isOn = false
        try WeightMapping.prepare(url)
        #expect(try Data(contentsOf: url) == untouched)
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("paged").path))
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("paged-partial").path))

        // Cut short, then mapping switched off: it is still finished, or nothing could load the file.
        #expect(throws: AlignedWeights.Failure.self) { try AlignedWeights.align(url, chunk: 50_000, stopAfter: 3) }
        try WeightMapping.prepare(url)
        try expectRearranged(url, from: tensors, originalSize: size)

        // Mapping on: a fresh file is rearranged, and one that cannot be is left to load the ordinary way.
        WeightMapping.isOn = true
        let fresh = directory.appendingPathComponent("fresh.safetensors")
        let freshSize = try write(tensors, to: fresh)
        try WeightMapping.prepare(fresh)
        try expectRearranged(fresh, from: tensors, originalSize: freshSize)
        let odd = directory.appendingPathComponent("odd.safetensors")
        try write(tensors, to: odd, extra: 10)
        let oddBefore = try Data(contentsOf: odd)
        try WeightMapping.prepare(odd)
        #expect(try Data(contentsOf: odd) == oddBefore)
    }
}
