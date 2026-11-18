import Foundation
import Testing

@testable import HarnessKit

@Suite struct ModelFilesTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("model-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A safetensors file in outline: the header's length, the header, then `bytes` of tensors.
    private func weights(header: String, bytes: Int) -> Data {
        var data = Data((0 ..< 8).map { UInt8(truncatingIfNeeded: header.utf8.count >> (8 * $0)) })
        data.append(Data(header.utf8))
        data.append(Data(repeating: 7, count: bytes))
        return data
    }

    @Test func `a file of the size it was downloaded at is whole`() throws {
        let url = try folder().appendingPathComponent("model.safetensors")
        try weights(header: #"{"a":{"dtype":"U8","shape":[10],"data_offsets":[0,10]}}"#, bytes: 10).write(to: url)
        let size = Int64(try Data(contentsOf: url).count)
        #expect(ModelDownloader.isWhole(url, size: size))
        #expect(!ModelDownloader.isWhole(url, size: size + 1))
        #expect(!ModelDownloader.isWhole(url, size: size - 1))
    }

    @Test func `a rearranged weights file is whole at the size its header records`() throws {
        let url = try folder().appendingPathComponent("model.safetensors")
        let header = #"{"__metadata__":{"resident.original_size":"4000","resident.page":"16384"},"a":{"dtype":"U8","shape":[10],"data_offsets":[0,10]}}"#
        try weights(header: header, bytes: 20000).write(to: url)
        #expect(ModelDownloader.isWhole(url, size: 4000))
        // Not for another size, and not for a file that is not weights.
        #expect(!ModelDownloader.isWhole(url, size: 4001))
        let other = url.deletingLastPathComponent().appendingPathComponent("tokenizer.json")
        try weights(header: header, bytes: 20000).write(to: other)
        #expect(!ModelDownloader.isWhole(other, size: 4000))
    }

    @Test func `a file cut short is not whole`() throws {
        let url = try folder().appendingPathComponent("model.safetensors")
        try Data(repeating: 1, count: 100).write(to: url)
        #expect(!ModelDownloader.isWhole(url, size: 4000))
        #expect(!ModelDownloader.isWhole(url.appendingPathExtension("missing"), size: 4000))
    }

    @Test func `second copies from an earlier version are removed and nothing else`() throws {
        let models = try folder()
        let model = models.appendingPathComponent("org__model")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        for name in ["model.safetensors", "model.safetensors.paged", "model.safetensors.paged-partial", "config.json", "prompt-cache-1.safetensors"] {
            try Data(repeating: 1, count: 1000).write(to: model.appendingPathComponent(name))
        }
        let freed = ModelDownloader.removeLeftoverCopies(in: models)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: model.path))
        #expect(freed == 2000)
        #expect(left == ["model.safetensors", "config.json", "prompt-cache-1.safetensors"])
        #expect(ModelDownloader.removeLeftoverCopies(in: models) == 0)
    }
}
