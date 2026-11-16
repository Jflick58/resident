import Foundation
import HarnessKit
import MLX
import MLXGuidedGeneration
import MLXLMCommon

/// Constrains tool calls to valid syntax while leaving everything else free.
///
/// The model writes text and thinking as usual. The moment it opens a
/// `<tool_call>`, the grammar takes over: only a declared tool name can follow,
/// and the arguments must match that tool's JSON Schema, token by token. A
/// small model can still pick the wrong tool, but it cannot emit a call that
/// fails to parse.
///
/// This covers models that write tool calls as Hermes-style JSON
/// (`<tool_call>{"name": …, "arguments": …}</tool_call>`), which includes the
/// Qwen and Llama families. Other formats run unconstrained.
enum ToolCallGrammar {
    /// The XGrammar structural tag for a set of tools.
    static func structuralTag(for tools: [HarnessKit.ToolSpec]) -> String {
        let tags: [HarnessKit.JSONValue] = tools.map { tool in
            [
                "type": "tag",
                "begin": .string("<tool_call>\n{\"name\": \(HarnessKit.JSONValue.string(tool.name).jsonString), \"arguments\": "),
                "content": ["type": "json_schema", "json_schema": tool.parameters],
                "end": ["}\n</tool_call>"],
            ]
        }
        let tag: HarnessKit.JSONValue = [
            "type": "structural_tag",
            "format": [
                "type": "triggered_tags",
                "triggers": ["<tool_call>"],
                "tags": .array(tags),
                "at_least_one": false,
                "stop_after_first": false,
            ],
        ]
        return tag.jsonString
    }

    /// Builds a processor factory, or nil when the grammar cannot be compiled for this model.
    static func processorFactory(
        tools: [HarnessKit.ToolSpec], tokenizer: any Tokenizer
    ) -> (@Sendable () -> any LogitProcessor)? {
        guard !tools.isEmpty else { return nil }
        do {
            let vocabulary = TokenizerVocabExtractor.extractForGrammar(from: tokenizer)
            let grammarTokenizer = try GrammarTokenizer(
                vocab: vocabulary.vocab, vocabType: vocabulary.vocabType,
                eosTokenId: Int32(tokenizer.eosTokenId ?? 0))
            let constraint = try GrammarConstraint(
                tokenizer: grammarTokenizer, structuralTag: structuralTag(for: tools),
                hostTokenizer: tokenizer)
            let vocabSize = grammarTokenizer.vocabSize
            return {
                // Each generation gets its own matcher over the shared compiled grammar.
                let matcher = (try? constraint.freshMatcher()) ?? constraint
                return ToolCallGrammarProcessor(constraint: matcher, vocabSize: vocabSize)
            }
        } catch {
            return nil
        }
    }
}

struct ToolCallGrammarProcessor: LogitProcessor {
    private final class State: @unchecked Sendable {
        /// Set when the grammar and the model disagree; from then on the turn runs unconstrained.
        var disabled = false
    }

    private let constraint: GrammarConstraint
    private let vocabSize: Int
    private let state = State()

    init(constraint: GrammarConstraint, vocabSize: Int) {
        self.constraint = constraint
        self.vocabSize = vocabSize
    }

    mutating func prompt(_ prompt: MLXArray) {}

    func process(logits: MLXArray) -> MLXArray {
        guard !state.disabled, let mask = try? constraint.computeMask(), mask.needsApply, !mask.isTerminated
        else { return logits }

        let width = logits.dim(-1)
        var penalties = [Float](repeating: -Float.infinity, count: width)
        mask.mask.withUnsafeBufferPointer { buffer in
            for index in 0..<min(vocabSize, width) {
                let word = UInt32(bitPattern: buffer[index / 32])
                if (word >> UInt32(index % 32)) & 1 == 1 { penalties[index] = 0 }
            }
        }
        return logits + MLXArray(penalties)
    }

    mutating func didSample(token: MLXArray) {
        guard !state.disabled else { return }
        let id: Int32 = token.item(Int32.self)
        // Stop tracking once the grammar has seen the end of the turn, or if it and the model disagree.
        guard let result = try? constraint.commitToken(id), !result.isTerminated else {
            state.disabled = true
            return
        }
    }

    func copy() -> ToolCallGrammarProcessor {
        ToolCallGrammarProcessor(
            constraint: (try? constraint.freshMatcher()) ?? constraint, vocabSize: vocabSize)
    }
}
