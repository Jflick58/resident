import Foundation
import Testing

@testable import MLXLMCommon

/// Tests for the rule that carries on from a cache whose generated turns a
/// render does not reproduce, for caches that cannot rewind.
@Suite
struct KeepGeneratedTurnsRuleTests {

    // A made-up vocabulary in the shape of a ChatML prompt.
    private let start = 100
    private let end = 101
    private let line = 102
    private let system = 110
    private let user = 111
    private let assistant = 112

    /// A system turn, a user turn and the header of the assistant's reply.
    private var opening: [Int] {
        [start, system, line, 1, 2, end, line, start, user, line, 3, 4, end, line, start, assistant, line]
    }

    /// What a template adds for a tool result or a new message, up to the next reply's header.
    private func next(_ content: [Int]) -> [Int] {
        [line, start, user, line] + content + [end, line, start, assistant, line]
    }

    private func turn(_ prompt: [Int], ends: Set<Int>? = nil) -> PromptCacheTurn {
        PromptCacheTurn(promptTokens: prompt, turnEndTokens: ends ?? [end])
    }

    private func cache(_ cached: [Int], spans: [Range<Int>], canTrim: Int = 0) -> PromptCacheState {
        PromptCacheState(
            cachedTokens: cached, processedTokenCount: cached.count, mainCacheIsAligned: true,
            maxTrimCount: canTrim, generatedSpans: spans)
    }

    private let policy = PromptCacheReusePolicy()

    @Test func `a turn rendered differently is kept as the model wrote it`() {
        // The model wrote 5 6 7 and stopped; the render has the same turn as 6 5 7.
        let cached = opening + [5, 6, 7, end]
        let added = next([8])
        let prompt = opening + [6, 5, 7, end] + added

        let decision = policy.decide(
            turn: turn(prompt), cache: cache(cached, spans: [opening.count ..< cached.count]))

        #expect(
            decision
                == .appendSuffix(suffixStart: opening.count + 4, representedTokens: cached + added))
    }

    @Test func `a turn cut short gets its end from the prompt`() {
        // Stopped at the token limit: the cache has no end of turn, so the suffix starts with it.
        let cached = opening + [5, 6, 7]
        let added = next([8])
        let prompt = opening + [6, 5] + [end] + added

        let decision = policy.decide(
            turn: turn(prompt), cache: cache(cached, spans: [opening.count ..< cached.count]))

        #expect(
            decision
                == .appendSuffix(
                    suffixStart: opening.count + 2, representedTokens: cached + [end] + added))
    }

    @Test func `earlier turns the render shortens are kept too`() {
        // Two replies. The render drops the reasoning (20 21) from the first once a new
        // message follows, and writes the second in another order.
        let first = opening + [20, 21, 5, end]
        let between = next([8])
        let cached = first + between + [6, 7, end]
        let added = next([9])
        let prompt = opening + [5, end] + between + [7, 6, end] + added

        let spans = [opening.count ..< first.count, (first.count + between.count) ..< cached.count]
        let decision = policy.decide(turn: turn(prompt), cache: cache(cached, spans: spans))

        #expect(
            decision
                == .appendSuffix(
                    suffixStart: prompt.count - added.count, representedTokens: cached + added))
    }

    @Test func `a cache that can rewind reads the render's version as before`() {
        let cached = opening + [5, 6, 7, end]
        let prompt = opening + [6, 5, 7, end] + next([8])

        let decision = policy.decide(
            turn: turn(prompt),
            cache: cache(cached, spans: [opening.count ..< cached.count], canTrim: cached.count))

        #expect(decision == .trimToCommonPrefix(commonPrefixLength: opening.count, trimCount: 4))
    }

    @Test func `a change outside the generated turns reads everything again`() {
        // The system turn differs: nothing the model wrote explains that.
        let cached = opening + [5, 6, 7, end]
        var changed = opening
        changed[3] = 50
        let prompt = changed + [6, 5, 7, end] + next([8])

        let decision = policy.decide(
            turn: turn(prompt), cache: cache(cached, spans: [opening.count ..< cached.count]))

        #expect(decision == .rebuild)
    }

    @Test func `a turn the template left out is not skipped over`() {
        // The render has no reply at all where the cache has one: the next end of turn
        // belongs to another message.
        let cached = opening + [5, 6, 7, end]
        let prompt = Array(opening.dropLast(3)) + next([8])

        let decision = policy.decide(
            turn: turn(prompt), cache: cache(cached, spans: [opening.count ..< cached.count]))

        #expect(decision == .rebuild)
    }

    @Test func `a cache holding far more than the render reads everything again`() {
        // 2,000 tokens of reasoning the render no longer has.
        let reasoning = Array(repeating: 30, count: 2000)
        let cached = opening + reasoning + [5, end]
        let prompt = opening + [5, end] + next([8])

        let decision = policy.decide(
            turn: turn(prompt), cache: cache(cached, spans: [opening.count ..< cached.count]))

        #expect(decision == .rebuild)
    }

    @Test func `without a record of what was generated nothing is kept`() {
        let cached = opening + [5, 6, 7, end]
        let prompt = opening + [6, 5, 7, end] + next([8])

        #expect(policy.decide(turn: turn(prompt), cache: cache(cached, spans: [])) == .rebuild)
        #expect(
            policy.decide(
                turn: turn(prompt, ends: []),
                cache: cache(cached, spans: [opening.count ..< cached.count])) == .rebuild)
    }

    @Test func `a prompt that only extends the cache is fed as before`() {
        let cached = opening + [5, 6, 7, end]
        let prompt = cached + next([8])

        let decision = policy.decide(
            turn: turn(prompt), cache: cache(cached, spans: [opening.count ..< cached.count]))

        #expect(decision == .appendSuffix(suffixStart: cached.count, representedTokens: prompt))
    }

    @Test func `the prompt must add something after the kept turns`() {
        let cached = opening + [5, 6, 7, end]
        let prompt = opening + [6, 5, 7, end]

        let decision = policy.decide(
            turn: turn(prompt), cache: cache(cached, spans: [opening.count ..< cached.count]))

        #expect(decision == .rebuild)
    }
}
