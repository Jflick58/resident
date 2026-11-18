import Foundation
import Testing

#if canImport(Metal)
import Metal
#endif

@testable import MLXLMCommon

/// Tests for how a rearranged weights file is mapped for the GPU. No model: the file is
/// written here, and the GPU is asked to read it the way MLX would.
@Suite(.serialized)
struct PagedWeightsTests {

    static var hasGPU: Bool {
        #if canImport(Metal)
        return MTLCreateSystemDefaultDevice() != nil
        #else
        return false
        #endif
    }

    /// A rearranged safetensors file holding one large tensor and one small one.
    private func weightsFile(large count: Int = 4 * 1024 * 1024) throws -> (url: URL, large: Data) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("paged-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("model.safetensors")
        let small = Data((0 ..< 100).map { UInt8(truncatingIfNeeded: $0) })
        let large = Data((0 ..< count).map { UInt8(truncatingIfNeeded: ($0 &* 31) ^ ($0 >> 9)) })
        let entries: [String: Any] = [
            "__metadata__": ["format": "mlx"],
            "norm.weight": ["dtype": "U8", "shape": [small.count], "data_offsets": [0, small.count]],
            "layer.weight": ["dtype": "U8", "shape": [large.count], "data_offsets": [small.count, small.count + large.count]],
        ]
        let header = try JSONSerialization.data(withJSONObject: entries)
        var data = Data((0 ..< 8).map { UInt8(truncatingIfNeeded: header.count >> (8 * $0)) })
        data.append(header)
        data.append(small)
        data.append(large)
        try data.write(to: url)
        try AlignedWeights.align(url)
        return (url, large)
    }

    /// Where the large tensor starts in the rearranged file.
    private func offset(of name: String, in url: URL) throws -> Int {
        let descriptor = open(url.path, O_RDONLY)
        defer { close(descriptor) }
        let header = try AlignedWeights.readHeader(descriptor)
        let entry = try #require(header.entries.first { $0.name == name })
        return header.dataStart + entry.begin
    }

    @Test(.enabled(if: hasGPU)) func `the GPU reads the file's own pages, not copies of them`() throws {
        let (url, large) = try weightsFile()
        let weights = try PagedWeights(source: url)
        #expect(weights.sharesPages)

        // The GPU goes over the whole mapping, as a model goes over its weights.
        let bytes = weights.bytes
        #expect(PagedWeights.gpuReads(try #require(bytes.baseAddress), length: bytes.count))

        let held = weights.held
        #expect(held.mapped == bytes.count)
        #expect(held.inMemory > 0)
        // A private mapping fails here: every page the GPU touched is then a copy.
        #expect(held.copied == 0)
        #expect(held.compressed == 0)
        #expect(held.readsFilePages)

        // What is mapped is the file: the tensor lies where the header says.
        let start = try offset(of: "layer.weight", in: url)
        #expect(Data(bytes[start ..< (start + large.count)]) == large)
    }

    @Test(.enabled(if: hasGPU)) func `what has been read can be pinned, let go and pinned again`() throws {
        guard #available(macOS 15, iOS 18, *) else { return }
        let (url, _) = try weightsFile()
        let weights = try PagedWeights(source: url, shared: true)
        #expect(weights.held.pinned == 0)

        // The GPU goes over the weights, as a model does in its first reply.
        let bytes = weights.bytes
        #expect(PagedWeights.gpuReads(try #require(bytes.baseAddress), length: bytes.count))
        weights.pin(holding: true)
        let pinned = weights.held.pinned
        #expect(pinned >= 4 * 1024 * 1024 && pinned <= bytes.count)
        // Pinning adds no copies: the pages pinned are the file's own.
        #expect(weights.held.copied == 0)
        // Asked again, it pins nothing twice.
        weights.pin(holding: true)
        #expect(weights.held.pinned == pinned)

        weights.unpin()
        #expect(weights.held.pinned == 0)
        weights.pin(holding: true)
        #expect(weights.held.pinned == pinned)
        weights.unpin()
    }

    @Test(.enabled(if: hasGPU)) func `holding is asked for from any thread and done on another`() throws {
        guard #available(macOS 15, iOS 18, *) else { return }
        let (url, _) = try weightsFile()
        let (isOn, shares, holds) = (WeightMapping.isOn, WeightMapping.sharesPages, WeightMapping.holds)
        defer { (WeightMapping.isOn, WeightMapping.sharesPages, WeightMapping.holds) = (isOn, shares, holds) }
        (WeightMapping.isOn, WeightMapping.sharesPages, WeightMapping.holds) = (true, true, true)
        let weights = try PagedWeights.shared(for: url)
        #expect(PagedWeights.gpuReads(try #require(weights.bytes.baseAddress), length: weights.bytes.count))

        WeightMapping.hold()
        PagedWeights.settlePinning()
        #expect(weights.held.pinned > 0 && WeightMapping.held.pinned >= weights.held.pinned)
        WeightMapping.release()
        PagedWeights.settlePinning()
        #expect(weights.held.pinned == 0)

        // Switched off, a hold does nothing.
        WeightMapping.holds = false
        WeightMapping.hold()
        PagedWeights.settlePinning()
        #expect(weights.held.pinned == 0)
    }

    @Test func `a mapping can be made private, and says so`() throws {
        let (url, large) = try weightsFile(large: 256 * 1024)
        #expect(WeightMapping.sharesPages)
        let weights = try PagedWeights(source: url, shared: false)
        #expect(!weights.sharesPages)
        #expect(!weights.held.readsFilePages)
        let start = try offset(of: "layer.weight", in: url)
        #expect(Data(weights.bytes[start ..< (start + large.count)]) == large)
    }

    @Test func `a file not rearranged has nothing to use in place`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("paged-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("model.safetensors")
        // One large tensor right after a header of no particular length: not on a page boundary.
        let body = Data(repeating: 7, count: 256 * 1024)
        let header = try JSONSerialization.data(withJSONObject: [
            "layer.weight": ["dtype": "U8", "shape": [body.count], "data_offsets": [0, body.count]]
        ])
        var data = Data((0 ..< 8).map { UInt8(truncatingIfNeeded: header.count >> (8 * $0)) })
        data.append(header)
        data.append(body)
        try data.write(to: url)
        #expect((8 + header.count) % AlignedWeights.page != 0)

        #expect(throws: AlignedWeights.Failure.self) { _ = try PagedWeights(source: url) }
    }
}
