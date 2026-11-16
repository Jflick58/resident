import Foundation
import MLX
import MLXLMCommon

/// Holds a model still between two tokens.
///
/// iOS takes the graphics processor from an app that has left the screen, and
/// a reply stopped for that reason can only be started again from the top of
/// the step. Held at the gate instead, the model makes no graphics-processor
/// calls while the app is away and writes its next token when the gate opens:
/// the reply carries on from the word it reached.
public enum GenerationGate {
    private static let condition = NSCondition()
    nonisolated(unsafe) private static var closed = false

    /// Stops generation at the next token.
    public static func close() {
        condition.lock()
        closed = true
        condition.unlock()
    }

    /// Lets generation carry on.
    public static func open() {
        condition.lock()
        closed = false
        condition.broadcast()
        condition.unlock()
    }

    static func wait() {
        condition.lock()
        while closed { condition.wait() }
        condition.unlock()
    }
}

/// Passes each token's logits through the gate, then on to whatever processor was already in use.
struct GatedProcessor: LogitProcessor {
    var inner: (any LogitProcessor)?

    mutating func prompt(_ prompt: MLXArray) { inner?.prompt(prompt) }

    func process(logits: MLXArray) -> MLXArray {
        GenerationGate.wait()
        return inner?.process(logits: logits) ?? logits
    }

    mutating func didSample(token: MLXArray) { inner?.didSample(token: token) }
    mutating func didEmit(token: Int) { inner?.didEmit(token: token) }
    mutating func finalizeGeneration() { inner?.finalizeGeneration() }
    func copy() -> GatedProcessor { GatedProcessor(inner: inner?.copy()) }
}
