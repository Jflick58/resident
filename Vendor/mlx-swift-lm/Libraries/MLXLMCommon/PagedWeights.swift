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
/// The file can be mapped two ways, and which is better on a phone is not settled.
///
/// Private, the way it is by default: the system hands the GPU its own copy of every page it
/// touches. The copies are not charged to the app either, but they are no longer pages of the
/// file: the system cannot drop them, only compress them, and packed weights do not compress.
/// A model that fills a phone's memory then leaves the system nothing it can give back. On a
/// 12 GB phone a 27B started at 11.5 tokens a second and fell to 0.6 over five steps, with
/// 7.4 GB of copies in the compressor by the end.
///
/// Shared (`sharesPages`): the GPU reads the file's own pages, with no copy. On a Mac it is
/// the same speed with nothing copied. On the phone the one trial of it was reported slower
/// from the first reply, before anything had been measured there, so it is off until it has
/// been. The mapping is read only either way, and a write through it changes nothing.
public enum WeightMapping {
    /// Off unless something turns it on before a model is loaded.
    nonisolated(unsafe) public static var isOn = false
    /// Tensors smaller than this are loaded the usual way: a page each would waste more than it saves.
    static let smallest = 64 * 1024
    /// Whether the next file is mapped shared. `HARNESS_MAP=shared` or `held` starts with it on.
    nonisolated(unsafe) public static var sharesPages = ["shared", "held"].contains(ProcessInfo.processInfo.environment["HARNESS_MAP"] ?? "")
    /// Whether `hold()` does anything. `HARNESS_MAP=held` starts with it on.
    nonisolated(unsafe) public static var holds = ProcessInfo.processInfo.environment["HARNESS_MAP"] == "held"

    /// Keeps in memory the weights that have been read, and whatever is read from here on, until `release()`.
    ///
    /// Nothing else does. The GPU has the pages it is using kept in place, but only while it is
    /// using them: on a 12 GB phone, in the half minute its user took to type a second message,
    /// the system took 3.5 GB of a 27B's weights back, and the reply that then needed them all
    /// again ended with the app being closed. So the app says when the model is at work. While
    /// it is, what the model has read is pinned (a Metal residency set over the same pages). When
    /// it is not, the pages are given up, and with a shared mapping the system can have them for
    /// nothing: they are the file's, and are read back when the next reply starts.
    public static func hold() {
        guard holds, isOn else { return }
        PagedWeights.holdAll()
    }

    /// Lets go of what `hold()` pinned.
    public static func release() { PagedWeights.releaseAll() }

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
        /// Pinned in memory by `hold()` right now.
        public var pinned = 0
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
    ///
    /// When the file is wanted mapped the other way (shared, or private) a new mapping is made. The
    /// old one is left mapped and unused: something may still hold a view into it, and what it
    /// costs is address space, since the system takes back pages nothing touches.
    static func shared(for url: URL) throws -> PagedWeights {
        lock.lock()
        defer { lock.unlock() }
        if let existing = open[url.path] {
            if existing.sharesPages == WeightMapping.sharesPages { return existing }
            existing.unpin()
            retired.append(existing)
        }
        let made = try PagedWeights(source: url)
        open[url.path] = made
        return made
    }

    /// Mappings replaced by one made the other way, kept so their memory stays mapped.
    nonisolated(unsafe) private static var retired: [PagedWeights] = []

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
            held.pinned += one.pinned
            if !one.readsFilePages { held.readsFilePages = false }
        }
        return held
    }

    /// Where pinning is done, one thing at a time and never on the caller's thread: asking for
    /// pages the system took back means reading them from storage, gigabytes of them, and the
    /// caller is often the main thread.
    private static let pinning = DispatchQueue(label: "resident.weights.pinning", qos: .userInitiated)
    /// Follows the weights as they are read while they are held: once a second, what has come into memory is pinned too.
    nonisolated(unsafe) private static var follower: DispatchSourceTimer?

    private static var all: [PagedWeights] {
        lock.lock()
        defer { lock.unlock() }
        return Array(open.values)
    }

    static func holdAll() {
        pinning.async {
            for weights in all { weights.pin(holding: true) }
            guard follower == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: pinning)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { for weights in all { weights.pin(holding: true) } }
            timer.resume()
            follower = timer
        }
    }

    static func releaseAll() {
        pinning.async {
            follower?.cancel()
            follower = nil
            for weights in all { weights.unpin() }
        }
    }

    /// Waits until every hold and release asked for so far has been done. For tests.
    static func settlePinning() { pinning.sync {} }

    private let base: UnsafeMutableRawPointer
    private let length: Int
    /// True when the file is mapped shared, so the GPU reads its own pages.
    let sharesPages: Bool
    /// What `pin` keeps in memory: buffers over stretches of the mapping, in a residency set, and which pages they cover.
    private let pinLock = NSLock()
    private var pins: Pins?
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

    /// The stretches of a mapping pinned in memory. A residency set keeps its buffers' pages where they
    /// are for as long as residency is asked for, and they are the pages the model's own buffers use.
    private final class Pins {
        #if canImport(Metal)
        let device: any MTLDevice
        /// An `MTLResidencySet`, kept untyped so the class exists on systems before it did.
        let set: AnyObject
        var buffers: [any MTLBuffer] = []
        #endif
        var covered: [Bool]
        var bytes = 0
        var isHolding = false

        #if canImport(Metal)
        init(device: any MTLDevice, set: AnyObject, pages: Int) {
            self.device = device
            self.set = set
            covered = [Bool](repeating: false, count: pages)
        }
        #endif
    }

    /// The longest stretch one buffer covers. Residency is decided a buffer at a time.
    static let pinStretch = 256 << 20
    /// Stretches of pages in memory shorter than this are not worth a buffer of their own.
    static let smallestPin = 1 << 20

    /// Pins the pages that are in memory now and are not pinned yet, and asks for all that is pinned to stay.
    func pin(holding: Bool) {
        #if canImport(Metal)
        guard #available(macOS 15, iOS 18, *) else { return }
        pinLock.lock()
        defer { pinLock.unlock() }
        let page = Int(getpagesize())
        let count = (length + page - 1) / page
        if pins == nil {
            guard let device = MTLCreateSystemDefaultDevice(),
                let set = try? device.makeResidencySet(descriptor: MTLResidencySetDescriptor())
            else { return }
            pins = Pins(device: device, set: set, pages: count)
        }
        guard let pins, let set = pins.set as? any MTLResidencySet else { return }
        var flags = [CChar](repeating: 0, count: count)
        guard mincore(base, length, &flags) == 0 else { return }
        var added = false
        var index = 0
        while index < count {
            guard flags[index] & CChar(MINCORE_INCORE) != 0, !pins.covered[index] else {
                index += 1
                continue
            }
            // A stretch of pages in memory that nothing covers yet, up to the most one buffer takes.
            var end = index
            while end < count, end - index < Self.pinStretch / page, flags[end] & CChar(MINCORE_INCORE) != 0, !pins.covered[end] { end += 1 }
            let bytes = min((end - index) * page, length - index * page)
            // A whole number of pages only: the end of the file, when it is not one, is left out.
            let whole = bytes / page * page
            if whole >= Self.smallestPin,
                let buffer = pins.device.makeBuffer(
                    bytesNoCopy: base + index * page, length: whole, options: [.storageModeShared, .hazardTrackingModeUntracked],
                    deallocator: nil)
            {
                set.addAllocation(buffer)
                pins.buffers.append(buffer)
                pins.bytes += whole
                for covered in index ..< index + whole / page { pins.covered[covered] = true }
                added = true
            }
            index = end
        }
        if added { set.commit() }
        // Asked again each time: the system can let residency go while the GPU is idle, standing request or not.
        if holding {
            set.requestResidency()
            pins.isHolding = true
        }
        #endif
    }

    func unpin() {
        #if canImport(Metal)
        guard #available(macOS 15, iOS 18, *) else { return }
        pinLock.lock()
        defer { pinLock.unlock() }
        guard let pins, pins.isHolding, let set = pins.set as? any MTLResidencySet else { return }
        set.endResidency()
        pins.isHolding = false
        #endif
    }

    /// How this file's pages are held, by asking the system about each.
    var held: WeightMapping.Held {
        let page = Int(getpagesize())
        var held = WeightMapping.Held(mapped: length, readsFilePages: sharesPages)
        pinLock.lock()
        if let pins, pins.isHolding { held.pinned = pins.bytes }
        pinLock.unlock()
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
