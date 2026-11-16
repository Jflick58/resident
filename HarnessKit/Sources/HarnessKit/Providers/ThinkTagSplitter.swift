import Foundation

/// Separates `<think>…</think>` reasoning from answer text in a stream, for
/// servers that send thinking inline instead of in its own field. Handles tags
/// split across chunks.
public struct ThinkTagSplitter: Sendable {
    public enum Piece: Equatable, Sendable {
        case text(String)
        case reasoning(String)
    }

    private static let open = "<think>"
    private static let close = "</think>"

    private var insideThinking = false
    private var pending = ""

    public init() {}

    public mutating func feed(_ chunk: String) -> [Piece] {
        pending += chunk
        var pieces: [Piece] = []

        while !pending.isEmpty {
            let tag = insideThinking ? Self.close : Self.open
            if let range = pending.range(of: tag) {
                emit(String(pending[..<range.lowerBound]), into: &pieces)
                pending = String(pending[range.upperBound...])
                insideThinking.toggle()
                continue
            }
            // Hold back a tail that could be the start of a tag.
            let keep = Self.partialTagSuffixLength(pending, tag: tag)
            let ready = String(pending.dropLast(keep))
            emit(ready, into: &pieces)
            pending = String(pending.suffix(keep))
            break
        }
        return pieces
    }

    /// Call at end of stream to release anything held back.
    public mutating func finish() -> [Piece] {
        var pieces: [Piece] = []
        emit(pending, into: &pieces)
        pending = ""
        return pieces
    }

    private func emit(_ text: String, into pieces: inout [Piece]) {
        guard !text.isEmpty else { return }
        pieces.append(insideThinking ? .reasoning(text) : .text(text))
    }

    static func partialTagSuffixLength(_ text: String, tag: String) -> Int {
        let maxLength = min(text.count, tag.count - 1)
        guard maxLength > 0 else { return 0 }
        for length in stride(from: maxLength, through: 1, by: -1) {
            if tag.hasPrefix(text.suffix(length)) { return length }
        }
        return 0
    }
}
