import Foundation

/// A provider that plays back fixed turns. Used by tests, and by the app in the
/// simulator where on-device inference is not available.
public struct ScriptedProvider: ModelProvider {
    public struct Turn: Sendable {
        public var reasoning: String
        public var text: String
        public var toolCalls: [ToolCall]

        public init(reasoning: String = "", text: String = "", toolCalls: [ToolCall] = []) {
            self.reasoning = reasoning
            self.text = text
            self.toolCalls = toolCalls
        }
    }

    private let script: @Sendable (GenerationRequest) -> Turn
    private let delay: Duration

    /// `script` receives each request and returns the turn to play.
    public init(delay: Duration = .zero, script: @escaping @Sendable (GenerationRequest) -> Turn) {
        self.script = script
        self.delay = delay
    }

    /// Plays `turns` in order, one per request. Repeats the last turn when they run out.
    public init(turns: [Turn], delay: Duration = .zero) {
        let counter = Counter()
        self.init(delay: delay) { _ in
            let index = counter.next()
            return turns[min(index, turns.count - 1)]
        }
    }

    public func generate(_ request: GenerationRequest) -> AsyncThrowingStream<ProviderEvent, Error> {
        let turn = script(request)
        let delay = delay
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for piece in Self.pieces(turn.reasoning) {
                        if delay > .zero { try await Task.sleep(for: delay) }
                        continuation.yield(.reasoning(piece))
                    }
                    for piece in Self.pieces(turn.text) {
                        if delay > .zero { try await Task.sleep(for: delay) }
                        continuation.yield(.text(piece))
                    }
                    for call in turn.toolCalls { continuation.yield(.toolCall(call)) }
                    continuation.yield(.finished(turn.toolCalls.isEmpty ? .stop : .toolCalls, nil))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: CancellationError())
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Splits text into word-sized pieces so playback looks like streaming.
    static func pieces(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == " " || character == "\n" {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            let current = value
            value += 1
            return current
        }
    }
}
