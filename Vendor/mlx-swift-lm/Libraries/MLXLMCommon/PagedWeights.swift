import Foundation
import MLX

#if canImport(Metal)
import Metal
#endif

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
///
/// The file is mapped shared, not private. Through a private mapping the system hands the
/// GPU its own copy of every page it touches. The copies are not charged to the app either,
/// but they are no longer pages of the file: the system cannot drop them, only compress
/// them, and packed weights do not compress. A model that fills a phone's memory then leaves
/// the system nothing it can give back, and when it needs memory the whole phone stalls.
/// Through a shared mapping the GPU reads the file's own pages, and the first use of a page
/// costs no copy. The mapping is read only, and a write through it changes nothing.
public enum WeightMapping {
    /// Off unless something turns it on before a model is loaded.
    nonisolated(unsafe) public static var isOn = false
    /// Tensors smaller than this are loaded the usual way: a page each would waste more than it saves.
    static let smallest = 64 * 1024
    /// `HARNESS_MAP=private` maps the old way, to compare the two.
    static let sharesPages = ProcessInfo.processInfo.environment["HARNESS_MAP"] != "private"

    /// How the mapped weights are held right now, in bytes.
    public struct Held: Sendable {
        /// Mapped in all.
        public var mapped = 0
        /// In memory.
        public var inMemory = 0
        /// In memory as the system's own copies instead of the file's pages.
        public var copied = 0
        /// Copies the system has compressed to make room. Pages of the file are never compressed.
        public var compressed = 0
        /// False when a file had to be mapped privately, so the GPU works on copies.
        public var readsFilePages = true
    }

    public static var held: Held { PagedWeights.held }

    /// Puts a weights file right before it is read, whichever way it is about to be loaded.
    ///
    /// - A rearrangement that was cut short (the app was closed part-way) is finished: until
    ///   it is, the file is not whole, and nothing can load it.
    /// - With mapping on, a file not yet rearranged is rearranged.
    /// - The second copy an earlier version kept beside the file (`<name>.paged`) is removed.
    ///
    /// Throws only when the file is part-way through and cannot be finished. A file that
    /// cannot be rearranged at all is left as it was and loads the ordinary way.
    ///
    /// - Parameter progress: called as a rearrangement goes, with the bytes moved so far. An
    ///   8 GB file takes minutes, and without this a load shows nothing until it is over.
    public static func prepare(_ url: URL, progress: ((Int) -> Void)? = nil) throws {
        for leftover in ["paged", "paged-partial"] {
            try? FileManager.default.removeItem(at: url.appendingPathExtension(leftover))
        }
        guard isOn || AlignedWeights.isPartWay(url) else { return }
        do {
            try AlignedWeights.align(url, progress: progress)
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

    static var held: WeightMapping.Held {
        lock.lock()
        let all = Array(open.values)
        lock.unlock()
        var held = WeightMapping.Held()
        for weights in all {
            let one = weights.held
            held.mapped += one.mapped
            held.inMemory += one.inMemory
            held.copied += one.copied
            held.compressed += one.compressed
            if !one.readsFilePages { held.readsFilePages = false }
        }
        return held
    }

    private let base: UnsafeMutableRawPointer
    private let length: Int
    /// True when the file is mapped shared, so the GPU reads its own pages.
    let sharesPages: Bool
    /// Where each tensor that can be used in place starts in the mapping, and how long it is.
    private let places: [String: (offset: Int, bytes: Int)]

    /// Maps the file as it is. Tensors that start on a page boundary are used in place; in a file
    /// ``WeightMapping/prepare(_:)`` has rearranged, that is every large one.
    ///
    /// - Parameter shared: false maps privately without trying the shared way.
    init(source: URL, shared: Bool = WeightMapping.sharesPages) throws {
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
        guard fstat(descriptor, &status) == 0, status.st_size > 0, let first = places.values.map(\.offset).min() else {
            throw AlignedWeights.Failure.unreadable
        }
        let total = Int(status.st_size)

        // Shared when the GPU reads it that way, which one page of the first tensor shows.
        var mapped: UnsafeMutableRawPointer?
        if shared, let tried = mmap(nil, total, PROT_READ, MAP_SHARED, descriptor, 0), tried != MAP_FAILED {
            if Self.gpuReads(tried + first, length: page) { mapped = tried } else { munmap(tried, total) }
        }
        sharesPages = mapped != nil
        if mapped == nil, let tried = mmap(nil, total, PROT_READ, MAP_PRIVATE, descriptor, 0), tried != MAP_FAILED { mapped = tried }
        guard let mapped else { throw AlignedWeights.Failure.unreadable }
        base = mapped
        self.places = places
        length = total
    }

    /// True when the GPU reads this stretch of a mapping where it lies and gets the file's bytes.
    /// Where it cannot, MLX would quietly copy every tensor into memory of its own.
    static func gpuReads(_ pointer: UnsafeMutableRawPointer, length: Int) -> Bool {
        #if canImport(Metal)
        guard let device = MTLCreateSystemDefaultDevice(),
            let source = device.makeBuffer(
                bytesNoCopy: pointer, length: length, options: [.storageModeShared, .hazardTrackingModeUntracked], deallocator: nil),
            let target = device.makeBuffer(length: length, options: .storageModeShared),
            let commands = device.makeCommandQueue()?.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder()
        else { return false }
        blit.copy(from: source, sourceOffset: 0, to: target, destinationOffset: 0, size: length)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        return commands.error == nil && memcmp(target.contents(), pointer, length) == 0
        #else
        return false
        #endif
    }

    /// How this file's pages are held, by asking the system about each.
    var held: WeightMapping.Held {
        let page = Int(getpagesize())
        var held = WeightMapping.Held(mapped: length, readsFilePages: sharesPages)
        var pages = [CChar](repeating: 0, count: (length + page - 1) / page)
        guard mincore(base, length, &pages) == 0 else { return held }
        for flags in pages {
            let flags = Int32(UInt8(bitPattern: flags))
            if flags & MINCORE_INCORE != 0 {
                held.inMemory += page
                if flags & (MINCORE_COPIED | MINCORE_ANONYMOUS) != 0 { held.copied += page }
            } else if flags & MINCORE_PAGED_OUT != 0 {
                held.compressed += page
            }
        }
        return held
    }

    /// The tensor as a view of the mapped file, or nil when it cannot be used in place.
    func array(named name: String, like loaded: MLXArray) -> MLXArray? {
        guard let place = places[name], place.bytes == loaded.nbytes else { return nil }
        return MLXArray(rawPointer: base + place.offset, loaded.shape, dtype: loaded.dtype) {}
    }

    /// The whole mapping, for tests.
    var bytes: UnsafeMutableRawBufferPointer { UnsafeMutableRawBufferPointer(start: base, count: length) }
}
