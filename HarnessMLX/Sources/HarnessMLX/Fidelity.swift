import Foundation
import HarnessKit
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import Tokenizers

/// A request as the agent sent it to the model, kept so the same prompt can be put to another build of the model.
public struct RecordedRequest: Codable, Sendable {
    public var messages: [HarnessKit.Message]
    public var tools: [HarnessKit.ToolSpec]
    public var thinking: ThinkingLevel

    public init(_ request: GenerationRequest) {
        messages = request.messages
        tools = request.tools
        thinking = request.options.thinking
    }
}

/// How far a build of a model has moved from the build it was made from.
///
/// A model is published in several builds: the weights as trained, and the same weights rounded
/// to fewer bits in one way or another. Whether a build passes a task says little about the
/// rounding, since most builds pass most tasks and a model does not answer the same way twice.
/// This asks the question the rounding itself answers: given the same prompt, how differently
/// does the build want to continue?
///
/// The reference build is given each prompt and writes the start of its reply, always taking its
/// likeliest token. Each other build is then walked down that same reply and asked, at every
/// token, what it would have written there.
public enum BuildFidelity {
    /// The reference's reply to one prompt, with what it thought likely at each token.
    public struct Sample: Codable, Sendable {
        var prompt: [Int32]
        /// The tokens the reference wrote.
        var reply: [Int32]
        /// For each token of the reply, the reference's `kept` likeliest tokens and how likely it held each (as logarithms).
        var likeliest: [Int32]
        var likelihood: [Float]
    }

    public struct Score: Sendable {
        public var replies = 0
        public var tokens = 0
        /// How far the build's view of the next token is from the reference's, averaged over every
        /// token (the Kullback-Leibler divergence, in nats). Nothing lost is 0.
        public var divergence = 0.0
        /// The same for the token in twenty where the build was furthest off.
        public var divergenceAtWorst = 0.0
        /// Share of tokens where the build's likeliest token is the reference's.
        public var agreement = 0.0
        /// Share of replies the build would have written token for token.
        public var sameReplies = 0.0
        /// Prompts the build's own tokenizer or template read differently, so they could not be compared.
        public var unreadable = 0
    }

    /// Likeliest tokens kept per position. What is left over is counted as one lump.
    static let kept = 1024

    /// The reference's replies to `requests`, `replyTokens` at most each. A prompt longer than `promptLimit` gets nil.
    public static func samples(
        reference directory: URL, requests: [RecordedRequest], replyTokens: Int = 96, promptLimit: Int = 6000,
        progress: @escaping @Sendable (Int) -> Void = { _ in }
    ) async throws -> [Sample?] {
        let container = try await loadModelContainer(from: directory, using: #huggingFaceTokenizerLoader())
        return try await container.perform { context in
            var stops = context.configuration.eosTokenIds
            if let end = context.tokenizer.eosTokenId { stops.insert(end) }
            for token in context.configuration.extraEOSTokens {
                if let id = context.tokenizer.convertTokenToId(token) { stops.insert(id) }
            }
            var samples: [Sample?] = []
            for (index, request) in requests.enumerated() {
                progress(index)
                let input = try await input(for: request, in: context)
                let prompt = input.text.tokens.reshaped([-1]).asArray(Int32.self)
                guard prompt.count <= promptLimit else {
                    samples.append(nil)
                    continue
                }
                let cache = try context.model.newCache(parameters: nil)
                var output = try afterPrompt(input, model: context.model, cache: cache)
                var sample = Sample(prompt: prompt, reply: [], likeliest: [], likelihood: [])
                for _ in 0 ..< replyTokens {
                    let token = autoreleasepool { argMax(output.logits[0, -1, 0...]).item(Int32.self) }
                    sample.reply.append(token)
                    if stops.contains(Int(token)) { break }
                    output = autoreleasepool {
                        let next = context.model.nextTokenLogits(
                            LMInput.Text(tokens: MLXArray([token]))[text: .newAxis], cache: cache.isEmpty ? nil : cache, state: output.state)
                        eval(next.logits)
                        return next
                    }
                }
                // What it held likely at each token is read the way a build's is, in one pass over the
                // reply: a token at a time the same weights give slightly different numbers.
                autoreleasepool {
                    let rows = try? likelihoods(of: sample.reply, after: input, model: context.model)
                    guard let rows else { return }
                    let order = argSort(-rows, axis: 1)[0..., 0 ..< kept]
                    let held = takeAlong(rows, order, axis: 1)
                    eval(order, held)
                    sample.likeliest = order.asArray(Int32.self)
                    sample.likelihood = held.asArray(Float.self)
                }
                guard !sample.likeliest.isEmpty else {
                    samples.append(nil)
                    continue
                }
                samples.append(sample)
                MLX.Memory.clearCache()
            }
            return samples
        }
    }

    /// How far the build in `directory` is from the reference that wrote `samples`.
    public static func score(
        _ directory: URL, against samples: [Sample?], requests: [RecordedRequest], progress: @escaping @Sendable (Int) -> Void = { _ in }
    ) async throws -> Score {
        let container = try await loadModelContainer(from: directory, using: #huggingFaceTokenizerLoader())
        return try await container.perform { context in
            var score = Score()
            var divergences: [Float] = []
            var agreed = 0
            var same = 0
            for (index, request) in requests.enumerated() {
                guard let sample = samples[index], !sample.reply.isEmpty else { continue }
                progress(index)
                let input = try await input(for: request, in: context)
                guard input.text.tokens.reshaped([-1]).asArray(Int32.self) == sample.prompt else {
                    score.unreadable += 1
                    continue
                }
                let (divergence, choices, theirChoices): ([Float], [Int32], [Int32]) = try autoreleasepool {
                    let rows = try likelihoods(of: sample.reply, after: input, model: context.model)
                    let count = sample.reply.count
                    let theirs = MLXArray(sample.likelihood, [count, kept])
                    let named = MLXArray(sample.likeliest, [count, kept])
                    let ours = takeAlong(rows, named, axis: 1)
                    let weight = exp(theirs)
                    // What the reference's list does not name is one lump on each side.
                    let theirRest = maximum(1 - weight.sum(axis: 1), 1e-9)
                    let ourRest = maximum(1 - exp(ours).sum(axis: 1), 1e-9)
                    let apart = (weight * (theirs - ours)).sum(axis: 1) + theirRest * (log(theirRest) - log(ourRest))
                    let chosen = argMax(rows, axis: 1)
                    eval(apart, chosen)
                    return (apart.asArray(Float.self), chosen.asArray(Int32.self), named[0..., 0].asArray(Int32.self))
                }
                let matches = zip(choices, theirChoices).filter { $0 == $1 }.count
                score.replies += 1
                score.tokens += sample.reply.count
                divergences += divergence.map { max(0, $0) }
                agreed += matches
                if matches == sample.reply.count { same += 1 }
                MLX.Memory.clearCache()
            }
            guard score.tokens > 0 else { return score }
            score.divergence = Double(divergences.reduce(0, +)) / Double(divergences.count)
            score.divergenceAtWorst = Double(divergences.sorted()[min(divergences.count - 1, divergences.count * 95 / 100)])
            score.agreement = Double(agreed) / Double(score.tokens)
            score.sameReplies = Double(same) / Double(score.replies)
            return score
        }
    }

    /// The prompt a new chat would give the model for this request, as the engine builds it.
    private static func input(for request: RecordedRequest, in context: ModelContext) async throws -> LMInput {
        var extra: [String: any Sendable]?
        if let reasoning = context.configuration.reasoningConfig {
            extra = try? reasoning.promptStrategy.additionalContext(forThinkingEnabled: request.thinking != .off)
        }
        let chat = try request.messages.map(MLXEngine.chatMessage)
        let tools: [MLXLMCommon.ToolSpec]? = request.tools.isEmpty ? nil : request.tools.map(MLXEngine.toolSpec)
        return try await context.processor.prepare(input: UserInput(chat: chat, tools: tools, additionalContext: extra))
    }

    /// Reads the prompt into `cache` and returns what the model would write next, the way generation does.
    private static func afterPrompt(_ input: LMInput, model: any LanguageModel, cache: [KVCache]) throws -> LMOutput {
        switch try model.prepare(input, cache: cache, state: nil, prefill: PrefillParameters()) {
        case .tokens(let rest):
            let output = model.nextTokenLogits(rest[text: .newAxis], cache: cache.isEmpty ? nil : cache, state: nil)
            eval(output.logits)
            return output
        case .logits(let output):
            eval(output.logits)
            return output
        }
    }

    /// For each token of `reply`, how likely the model holds every token of its vocabulary to come there,
    /// as logarithms: the prompt read as generation reads it, then the reply in one pass.
    private static func likelihoods(of reply: [Int32], after input: LMInput, model: any LanguageModel) throws -> MLXArray {
        let cache = try model.newCache(parameters: nil)
        let first = try afterPrompt(input, model: model, cache: cache)
        var rows = normalized(first.logits[0, -1, 0...])[.newAxis]
        if reply.count > 1 {
            let rest = model(
                LMInput.Text(tokens: MLXArray(Array(reply.dropLast())))[text: .newAxis], cache: cache.isEmpty ? nil : cache, state: first.state)
            rows = concatenated([rows, normalized(rest.logits[0])], axis: 0)
        }
        eval(rows)
        return rows
    }

    /// Scores over the vocabulary, last axis, as the logarithm of how likely each token is.
    private static func normalized(_ logits: MLXArray) -> MLXArray {
        let scores = logits.asType(.float32)
        return scores - logSumExp(scores, axis: -1, keepDims: true)
    }
}
