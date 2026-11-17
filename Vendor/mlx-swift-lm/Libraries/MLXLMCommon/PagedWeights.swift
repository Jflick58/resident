import Foundation
import MLX

/// EXPERIMENT (Resident): weights used straight from a file mapped into memory.
///
/// iOS limits an app by the memory it has written to. `loadArrays` reads every weight
/// into memory MLX allocated, which counts in full, so a model has to be smaller than
/// the limit. Pages of a mapped file are different: the system can drop them and read
/// them back from disk, so they are not charged to the app. With the weights mapped,
/// what counts is the working memory of generation, not the size of the model.
///
/// The GPU takes outside memory only in whole pages that start on a page boundary, and
/// a safetensors file packs its tensors end to end. So each weights file gets a copy
/// beside it, `<name>.paged`, with every tensor moved to the start of a page. It is
/// written once, a few megabytes at a time, and mapped from then on.
public enum WeightMapping {
    /// Off unless something turns it on before a model is loaded.
    nonisolated(unsafe) public static var isOn = false
    /// Tensors smaller than this are loaded the usual way: a page each would waste more than it saves.
    static let smallest = 64 * 1024

    /// How much of the mapped weights is in memory right now, and how much is mapped, in bytes.
    public static var resident: (inMemory: Int, mapped: Int) { PagedWeights.resident }
}

final class PagedWeights: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var open: [String: PagedWeights] = [:]

    /// The mapping for a weights file, made on first use and kept for the life of the process.
    static func shared(for url: URL) throws -> PagedWeights {
        lock.lock()
        defer { lock.unlock() }
        if let existing = open[url.path] { return existing }
        let made = try PagedWeights(source: url)
        open[url.path] = made
        return made
    }

    static var resident: (inMemory: Int, mapped: Int) {
        lock.lock()
        let all = Array(open.values)
        lock.unlock()
        let page = Int(getpagesize())
        var inMemory = 0
        var mapped = 0
        for weights in all {
            mapped += weights.length
            var pages = [CChar](repeating: 0, count: (weights.length + page - 1) / page)
            if mincore(weights.base, weights.length, &pages) == 0 { inMemory += pages.reduce(0) { $0 + ($1 & 1 != 0 ? page : 0) } }
        }
        return (inMemory, mapped)
    }

    private let base: UnsafeMutableRawPointer
    private let length: Int
    /// Where each tensor starts in the mapping, and how long it is.
    private let places: [String: (offset: Int, bytes: Int)]

    private init(source: URL) throws {
        struct Malformed: Error {}
        let page = Int(getpagesize())
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        guard let lengthData = try reader.read(upToCount: 8), lengthData.count == 8 else { throw Malformed() }
        let headerLength = Int(lengthData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian)
        guard headerLength > 0, let headerData = try reader.read(upToCount: headerLength), headerData.count == headerLength,
            let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any]
        else { throw Malformed() }
        let dataStart = 8 + headerLength

        var spans: [(name: String, begin: Int, bytes: Int)] = []
        for (name, value) in header where name != "__metadata__" {
            guard let entry = value as? [String: Any], let offsets = entry["data_offsets"] as? [Any], offsets.count == 2,
                let begin = (offsets[0] as? NSNumber)?.intValue, let end = (offsets[1] as? NSNumber)?.intValue, end >= begin
            else { throw Malformed() }
            if end - begin >= WeightMapping.smallest { spans.append((name, dataStart + begin, end - begin)) }
        }
        spans.sort { $0.begin < $1.begin }

        var places: [String: (offset: Int, bytes: Int)] = [:]
        var total = 0
        for span in spans {
            places[span.name] = (total, span.bytes)
            total += (span.bytes + page - 1) / page * page
        }
        self.places = places

        let paged = source.appendingPathExtension("paged")
        let size = (try? FileManager.default.attributesOfItem(atPath: paged.path)[.size] as? NSNumber)?.intValue
        if size != total {
            // Written under another name and moved into place, so a copy that was cut short is never used.
            let partial = source.appendingPathExtension("paged-partial")
            FileManager.default.createFile(atPath: partial.path, contents: nil)
            let writer = try FileHandle(forWritingTo: partial)
            let chunk = 8 * 1024 * 1024
            for span in spans {
                try reader.seek(toOffset: UInt64(span.begin))
                var left = span.bytes
                while left > 0 {
                    // Each chunk is freed before the next is read. Without the pool they pile up
                    // until the loop ends, and the copy of a large model uses as much memory as the model.
                    left -= try autoreleasepool {
                        guard let data = try reader.read(upToCount: min(chunk, left)), !data.isEmpty else { throw Malformed() }
                        try writer.write(contentsOf: data)
                        return data.count
                    }
                }
                let padding = (page - span.bytes % page) % page
                if padding > 0 { try writer.write(contentsOf: Data(count: padding)) }
            }
            try writer.close()
            try? FileManager.default.removeItem(at: paged)
            try FileManager.default.moveItem(at: partial, to: paged)
        }

        let descriptor = Darwin.open(paged.path, O_RDONLY)
        guard descriptor >= 0 else { throw Malformed() }
        defer { close(descriptor) }
        guard total > 0, let base = mmap(nil, total, PROT_READ, MAP_PRIVATE, descriptor, 0), base != MAP_FAILED else { throw Malformed() }
        self.base = base
        length = total
    }

    /// The tensor as a view of the mapped file, or nil when it is not in the mapping.
    func array(named name: String, like loaded: MLXArray) -> MLXArray? {
        guard let place = places[name], place.bytes == loaded.nbytes else { return nil }
        return MLXArray(rawPointer: base + place.offset, loaded.shape, dtype: loaded.dtype) {}
    }
}
