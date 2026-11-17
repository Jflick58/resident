import Compression
import Foundation

/// Unpacks a `.tar.gz`, the form GitHub hands a repository out in.
///
/// The archive is read and unpacked a piece at a time, so a repository of any
/// size costs a few hundred kilobytes of memory. That matters on a phone whose
/// memory is mostly taken by the model.
enum Tarball {
    struct Malformed: Error {}

    /// Files larger than this are left out: nothing a model edits is that long.
    static let largestFile = 2 * 1024 * 1024

    /// Unpacks `archive` into `directory`, dropping the single folder a GitHub archive wraps
    /// everything in. Returns how many files were written and how many were left out.
    @discardableResult
    static func unpack(_ archive: URL, into directory: URL) throws -> (written: Int, skipped: Int) {
        let reader = try FileHandle(forReadingFrom: archive)
        defer { try? reader.close() }
        var tar = Untar(directory: directory)
        var inflater = try Inflater()
        defer { inflater.close() }
        var sawHeader = false
        while true {
            let more: Bool = try autoreleasepool {
                guard var chunk = try reader.read(upToCount: 64 * 1024), !chunk.isEmpty else { return false }
                if !sawHeader {
                    chunk = try withoutGzipHeader(chunk)
                    sawHeader = true
                }
                try inflater.feed(chunk) { try tar.consume($0) }
                return true
            }
            if !more { break }
        }
        return (tar.written, tar.skipped)
    }

    /// The first piece of a gzip file with its header taken off, leaving the compressed data.
    private static func withoutGzipHeader(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { throw Malformed() }
        let flags = bytes[3]
        var index = 10
        if flags & 4 != 0 { index += 2 + Int(bytes[index]) + Int(bytes[index + 1]) << 8 }
        for flag: UInt8 in [8, 16] where flags & flag != 0 {
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            index += 1
        }
        if flags & 2 != 0 { index += 2 }
        guard index < bytes.count else { throw Malformed() }
        return Data(bytes[index...])
    }
}

/// Decompresses deflate data as it arrives.
private struct Inflater {
    private let stream: UnsafeMutablePointer<compression_stream>
    private let output: UnsafeMutablePointer<UInt8>
    private let capacity = 128 * 1024
    private var finished = false

    init() throws {
        stream = .allocate(capacity: 1)
        output = .allocate(capacity: capacity)
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            stream.deallocate()
            output.deallocate()
            throw Tarball.Malformed()
        }
    }

    func close() {
        compression_stream_destroy(stream)
        stream.deallocate()
        output.deallocate()
    }

    mutating func feed(_ input: Data, to sink: (UnsafeRawBufferPointer) throws -> Void) throws {
        guard !finished else { return }
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = raw.count
            while true {
                stream.pointee.dst_ptr = output
                stream.pointee.dst_size = capacity
                let status = compression_stream_process(stream, 0)
                guard status != COMPRESSION_STATUS_ERROR else { throw Tarball.Malformed() }
                let produced = capacity - stream.pointee.dst_size
                if produced > 0 { try sink(UnsafeRawBufferPointer(start: output, count: produced)) }
                if status == COMPRESSION_STATUS_END {
                    finished = true
                    return
                }
                // Stops when the input is used up and a pass brought nothing more out. Room left
                // in the output is not enough to go by: a pass can end early with more to come.
                if stream.pointee.src_size == 0, produced == 0 { return }
            }
        }
    }
}

/// Reads a tar stream and writes its files under a directory.
private struct Untar {
    let directory: URL
    var written = 0
    var skipped = 0

    private var pending = Data()
    /// What the bytes after the current header are, and how many are left.
    private var body: (kind: Kind, left: Int, padding: Int)?
    private var collected = Data()
    /// A path given by a header that came before the file's own, for names too long for it.
    private var longPath: String?
    private var done = false

    private enum Kind {
        case file(String)
        case longName
        case extended
        case skip
    }

    init(directory: URL) { self.directory = directory }

    mutating func consume(_ bytes: UnsafeRawBufferPointer) throws {
        guard !done else { return }
        pending.append(contentsOf: bytes)
        var offset = pending.startIndex
        defer { pending.removeSubrange(pending.startIndex..<offset) }
        while !done {
            if let current = body {
                let available = pending.endIndex - offset
                guard available > 0 || current.left + current.padding == 0 else { return }
                let take = min(current.left, available)
                if take > 0 {
                    if case .skip = current.kind {} else { collected.append(pending[offset..<(offset + take)]) }
                    offset += take
                }
                let left = current.left - take
                let pad = min(current.padding, pending.endIndex - offset)
                if left == 0 { offset += pad }
                if left == 0, pad == current.padding {
                    try finish(current.kind)
                    body = nil
                } else {
                    body = (current.kind, left, left == 0 ? current.padding - pad : current.padding)
                    return
                }
            } else {
                guard pending.endIndex - offset >= 512 else { return }
                let header = [UInt8](pending[offset..<(offset + 512)])
                offset += 512
                if header.allSatisfy({ $0 == 0 }) {
                    done = true
                    return
                }
                func field(_ range: Range<Int>) -> String {
                    String(decoding: header[range].prefix { $0 != 0 }, as: UTF8.self)
                }
                let size = Int(field(124..<136).trimmingCharacters(in: .whitespaces), radix: 8) ?? 0
                let padding = (512 - size % 512) % 512
                let prefix = field(345..<500)
                let name = longPath ?? (prefix.isEmpty ? field(0..<100) : prefix + "/" + field(0..<100))
                collected = Data()
                switch header[156] {
                case UInt8(ascii: "0"), 0:
                    longPath = nil
                    if size > Tarball.largestFile {
                        skipped += 1
                        body = (.skip, size, padding)
                    } else {
                        body = (.file(name), size, padding)
                    }
                case UInt8(ascii: "L"): body = (.longName, size, padding)
                case UInt8(ascii: "x"): body = (.extended, size, padding)
                default:
                    if header[156] != UInt8(ascii: "g") { longPath = nil }
                    body = (.skip, size, padding)
                }
            }
        }
    }

    private mutating func finish(_ kind: Kind) throws {
        switch kind {
        case .skip: break
        case .longName: longPath = String(decoding: collected.prefix { $0 != 0 }, as: UTF8.self)
        case .extended:
            // Records of the form "<length> key=value\n".
            for record in String(decoding: collected, as: UTF8.self).split(separator: "\n") {
                guard let space = record.firstIndex(of: " ") else { continue }
                let pair = record[record.index(after: space)...]
                if pair.hasPrefix("path=") { longPath = String(pair.dropFirst(5)) }
            }
        case .file(let name):
            // The first part of every path is the folder GitHub wraps the repository in.
            let parts = name.split(separator: "/").dropFirst()
            guard !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else { return }
            let target = directory.appendingPathComponent(parts.joined(separator: "/"))
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try collected.write(to: target)
            written += 1
        }
        collected = Data()
    }
}
