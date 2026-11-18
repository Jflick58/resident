import Foundation

/// Resident: rearranges a safetensors file so that each large tensor starts on a page
/// boundary, without ever holding a second copy of it.
///
/// A mapped tensor can be handed to the GPU only if it starts at the start of a page
/// (see ``WeightMapping``). A safetensors file packs its tensors end to end, so they have to
/// be moved apart. Writing a rearranged copy beside the file is simple but doubles what a
/// model takes on disk, 16 GB for an 8 GB model, and needs that much free to begin with.
///
/// So the file is moved into its new arrangement from the end. The last tensor is copied to
/// its place in a new file, the old file is cut short by that much, then the one before it,
/// and so on. At every moment each byte is in one file or the other, and the two together
/// take the size of one. The old file's own length is the record of how far the move has
/// got, so a move that is cut short (the app is closed, the phone restarts) is carried on from
/// where it stopped. Last, the new file takes the old one's name.
///
/// The result is still a safetensors file that the ordinary loader reads: the header says
/// where each tensor is. It is a few megabytes longer than it was, and its header records the
/// size it had, for anything that knows the file by the size it was downloaded at.
public enum AlignedWeights {
    /// The page size tensors are aligned to. Every Apple device with a GPU that takes mapped
    /// memory has pages of this size, and a boundary of this size is one for smaller pages too.
    public static let page = 16384
    /// In the header's metadata: the size of the file before it was rearranged. Kept first in
    /// the header, so it can be found by reading the start of the file.
    public static let sizeKey = "resident.original_size"
    static let pageKey = "resident.page"
    static let partWayExtension = "aligning"

    public enum Failure: Error {
        case unreadable
        /// Not a whole safetensors file with its tensors end to end: left alone.
        case unexpectedLayout
        case storage(Int32)
        /// For tests: stopped on purpose part-way through.
        case interrupted
    }

    struct Entry {
        var name: String
        var dtype: String
        var shape: [Int]
        /// Where the tensor's bytes start and end, counted from the end of the header.
        var begin: Int
        var end: Int
        var bytes: Int { end - begin }
    }

    struct Header {
        /// Where the tensors start in the file: just after the header.
        var dataStart: Int
        var metadata: [String: String]
        /// In the order they lie in the file.
        var entries: [Entry]
        var dataEnd: Int { dataStart + (entries.map(\.end).max() ?? 0) }
    }

    /// True while a rearrangement of this file is under way and not finished.
    public static func isPartWay(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathExtension(partWayExtension).path)
    }

    /// True when every large tensor of the file already starts on a page boundary.
    public static func isAligned(_ url: URL) -> Bool {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard let header = try? readHeader(descriptor) else { return false }
        return isAligned(header)
    }

    static func isAligned(_ header: Header) -> Bool {
        header.entries.allSatisfy { $0.bytes < WeightMapping.smallest || (header.dataStart + $0.begin) % page == 0 }
    }

    static func readHeader(_ descriptor: Int32) throws -> Header {
        var lengthBytes = [UInt8](repeating: 0, count: 8)
        guard pread(descriptor, &lengthBytes, 8, 0) == 8 else { throw Failure.unreadable }
        let headerLength = lengthBytes.enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        // The largest header seen is a few hundred kilobytes; this is only a guard against reading nonsense.
        guard headerLength > 1, headerLength < 256 << 20 else { throw Failure.unreadable }
        var headerBytes = [UInt8](repeating: 0, count: headerLength)
        guard pread(descriptor, &headerBytes, headerLength, 8) == headerLength,
            let object = try? JSONSerialization.jsonObject(with: Data(headerBytes)) as? [String: Any]
        else { throw Failure.unreadable }

        var entries: [Entry] = []
        for (name, value) in object where name != "__metadata__" {
            guard let entry = value as? [String: Any], let dtype = entry["dtype"] as? String,
                let shape = entry["shape"] as? [NSNumber], let offsets = entry["data_offsets"] as? [NSNumber], offsets.count == 2,
                offsets[1].intValue >= offsets[0].intValue, offsets[0].intValue >= 0
            else { throw Failure.unreadable }
            entries.append(Entry(name: name, dtype: dtype, shape: shape.map(\.intValue), begin: offsets[0].intValue, end: offsets[1].intValue))
        }
        // Tensors of no length share an offset with their neighbour: the name keeps the order the same on every reading.
        entries.sort { ($0.begin, $0.end, $0.name) < ($1.begin, $1.end, $1.name) }
        let metadata = (object["__metadata__"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        return Header(dataStart: 8 + headerLength, metadata: metadata, entries: entries)
    }

    /// The new arrangement: where each tensor goes, and the header that says so.
    struct Plan {
        /// The whole start of the new file: the length, the header, and spaces up to a page boundary.
        var header: Data
        /// Where each tensor starts in the new file, in the order of `Header.entries`.
        var offsets: [Int]
        var length: Int
    }

    static func plan(for header: Header) throws -> Plan {
        func roundUp(_ value: Int, to unit: Int) -> Int { (value + unit - 1) / unit * unit }
        var offsets: [Int] = []
        var cursor = 0
        for entry in header.entries {
            cursor = roundUp(cursor, to: entry.bytes >= WeightMapping.smallest ? page : 8)
            offsets.append(cursor)
            cursor += entry.bytes
        }
        let dataLength = roundUp(cursor, to: page)

        func quoted(_ text: String) throws -> String {
            String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
        }
        var metadata = header.metadata
        // A file rearranged before keeps the size it was first recorded at.
        let original = metadata[sizeKey].flatMap(Int.init) ?? header.dataEnd
        metadata[sizeKey] = nil
        metadata[pageKey] = nil
        var fields = ["\(try quoted(sizeKey)):\"\(original)\"", "\(try quoted(pageKey)):\"\(page)\""]
        for key in metadata.keys.sorted() { fields.append("\(try quoted(key)):\(try quoted(metadata[key] ?? ""))") }
        var parts = ["\"__metadata__\":{\(fields.joined(separator: ","))}"]
        for (entry, offset) in zip(header.entries, offsets) {
            let shape = entry.shape.map(String.init).joined(separator: ",")
            parts.append(
                "\(try quoted(entry.name)):{\"dtype\":\(try quoted(entry.dtype)),\"shape\":[\(shape)],\"data_offsets\":[\(offset),\(offset + entry.bytes)]}")
        }
        var text = Data("{\(parts.joined(separator: ","))}".utf8)
        let dataStart = roundUp(8 + text.count, to: page)
        // A header may be padded with spaces: that is how the tensors after it come to start on a boundary.
        text.append(Data(repeating: 0x20, count: dataStart - 8 - text.count))
        var start = Data((0 ..< 8).map { UInt8(truncatingIfNeeded: text.count >> (8 * $0)) })
        start.append(text)
        return Plan(header: start, offsets: offsets.map { dataStart + $0 }, length: dataStart + dataLength)
    }

    /// Rearranges the file so every large tensor starts on a page boundary. Does nothing to a file
    /// that is already so, and carries on a rearrangement that was cut short.
    ///
    /// - Parameters:
    ///   - chunk: how much is moved at a time. Each piece is on storage before the old file gives it up.
    ///   - stopAfter: for tests, stops with ``Failure/interrupted`` after this many pieces.
    public static func align(_ url: URL, chunk: Int = 32 << 20, stopAfter: Int? = nil) throws {
        let partWay = url.appendingPathExtension(partWayExtension)
        let old = open(url.path, O_RDWR)
        guard old >= 0 else { throw Failure.unreadable }
        defer { close(old) }
        let header = try readHeader(old)
        var status = stat()
        guard fstat(old, &status) == 0 else { throw Failure.unreadable }
        var oldLength = Int(status.st_size)

        // Tensors must lie one after another without overlapping, or moving from the end would lose some.
        var last = 0
        for entry in header.entries {
            guard entry.begin >= last else { throw Failure.unexpectedLayout }
            last = entry.end
        }
        if isPartWay(url) {
            // Cut short earlier: the old file has lost its end to the new one, and never its header.
            guard oldLength >= header.dataStart, oldLength <= header.dataEnd else { throw Failure.unexpectedLayout }
        } else {
            if isAligned(header) { return }
            // Whole, with nothing after its last tensor: otherwise it is not what this was written for.
            guard oldLength == header.dataEnd else { throw Failure.unexpectedLayout }
        }

        let plan = try plan(for: header)
        let new = open(partWay.path, O_RDWR | O_CREAT, 0o644)
        guard new >= 0 else { throw Failure.storage(errno) }
        defer { close(new) }

        func onStorage(_ descriptor: Int32) throws {
            // The ordinary sync leaves data in the drive's own buffer; this one waits for it.
            if fcntl(descriptor, F_FULLFSYNC) != 0, fsync(descriptor) != 0 { throw Failure.storage(errno) }
        }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(1, chunk), alignment: 16384)
        defer { buffer.deallocate() }
        var moved = 0
        for (entry, place) in zip(header.entries, plan.offsets).reversed() {
            let begin = header.dataStart + entry.begin
            // What lies past the old file's end is already in the new one.
            var end = min(header.dataStart + entry.end, oldLength)
            while end > begin {
                let start = max(begin, end - chunk)
                var done = 0
                while done < end - start {
                    let count = pread(old, buffer + done, end - start - done, off_t(start + done))
                    guard count > 0 else { throw Failure.storage(errno) }
                    done += count
                }
                done = 0
                while done < end - start {
                    let count = pwrite(new, buffer + done, end - start - done, off_t(place + (start - begin) + done))
                    guard count > 0 else { throw Failure.storage(errno) }
                    done += count
                }
                try onStorage(new)
                guard ftruncate(old, off_t(start)) == 0 else { throw Failure.storage(errno) }
                oldLength = start
                end = start
                moved += 1
                if let stopAfter, moved >= stopAfter { throw Failure.interrupted }
            }
        }

        // Every tensor is in the new file. Its header goes in, it is made its full length, and it takes the name.
        let wrote = plan.header.withUnsafeBytes { pwrite(new, $0.baseAddress, $0.count, 0) }
        guard wrote == plan.header.count, ftruncate(new, off_t(plan.length)) == 0 else { throw Failure.storage(errno) }
        try onStorage(new)
        guard rename(partWay.path, url.path) == 0 else { throw Failure.storage(errno) }
    }
}
