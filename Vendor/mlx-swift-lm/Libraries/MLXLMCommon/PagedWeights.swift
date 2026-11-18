import Foundation
import MLX

/// Resident: weights used straight from a file mapped into memory.
///
/// iOS limits an app by the memory it has written to. `loadArrays` reads every weight
/// into memory MLX allocated, which counts in full, so a model has to be smaller than
/// the limit. Pages of a mapped file are different: the system can drop them and read
/// them back from disk, so they are not charged to the app. With the weights mapped,
/// what counts is the working memory of generation, not the size of the model.
///
/// The GPU takes outside memory only in whole pages that start on a page boundary, and
/// a safetensors file packs its tensors end to end. So before its first mapped load a
/// weights file is rearranged, in place, with every large tensor moved to the start of
/// a page (``AlignedWeights``). It stays one file, a few megabytes longer, and loads
/// the ordinary way as well.
public enum WeightMapping {
    /// Off unless something turns it on before a model is loaded.
    nonisolated(unsafe) public static var isOn = false
    /// Tensors smaller than this are loaded the usual way: a page each would waste more than it saves.
    static let smallest = 64 * 1024

    /// How much of the mapped weights is in memory right now, and how much is mapped, in bytes.
    public static var resident: (inMemory: Int, mapped: Int) { PagedWeights.resident }

    /// Puts a weights file right before it is read, whichever way it is about to be loaded.
    ///
    /// - A rearrangement that was cut short (the app was closed part-way) is finished: until
    ///   it is, the file is not whole, and nothing can load it.
    /// - With mapping on, a file not yet rearranged is rearranged.
    /// - The second copy an earlier version kept beside the file (`<name>.paged`) is removed.
    ///
    /// Throws only when the file is part-way through and cannot be finished. A file that
    /// cannot be rearranged at all is left as it was and loads the ordinary way.
    public static func prepare(_ url: URL) throws {
        for leftover in ["paged", "paged-partial"] {
            try? FileManager.default.removeItem(at: url.appendingPathExtension(leftover))
        }
        guard isOn || AlignedWeights.isPartWay(url) else { return }
        do {
            try AlignedWeights.align(url)
        } catch {
            if AlignedWeights.isPartWay(url) { throw error }
        }
    }
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
    /// Where each tensor that can be used in place starts in the mapping, and how long it is.
    private let places: [String: (offset: Int, bytes: Int)]

    /// Maps the file as it is. Tensors that start on a page boundary are used in place; in a file
    /// ``WeightMapping/prepare(_:)`` has rearranged, that is every large one.
    private init(source: URL) throws {
        let descriptor = Darwin.open(source.path, O_RDONLY)
        guard descriptor >= 0 else { throw AlignedWeights.Failure.unreadable }
        defer { close(descriptor) }
        let header = try AlignedWeights.readHeader(descriptor)
        let page = max(AlignedWeights.page, Int(getpagesize()))
        var places: [String: (offset: Int, bytes: Int)] = [:]
        for entry in header.entries where entry.bytes >= WeightMapping.smallest && (header.dataStart + entry.begin) % page == 0 {
            places[entry.name] = (header.dataStart + entry.begin, entry.bytes)
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_size > 0, !places.isEmpty else { throw AlignedWeights.Failure.unreadable }
        let total = Int(status.st_size)
        guard let base = mmap(nil, total, PROT_READ, MAP_PRIVATE, descriptor, 0), base != MAP_FAILED else {
            throw AlignedWeights.Failure.unreadable
        }
        self.base = base
        self.places = places
        length = total
    }

    /// The tensor as a view of the mapped file, or nil when it cannot be used in place.
    func array(named name: String, like loaded: MLXArray) -> MLXArray? {
        guard let place = places[name], place.bytes == loaded.nbytes else { return nil }
        return MLXArray(rawPointer: base + place.offset, loaded.shape, dtype: loaded.dtype) {}
    }
}
