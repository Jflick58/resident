// Copyright © 2025 Apple Inc.

import Foundation

/// How a newly rendered prompt should be reconciled with the tokens a live
/// KV cache already represents.
///
/// A decision describes *what* to do; applying it (trimming, rebuilding,
/// prefilling) belongs to whoever owns the caches.
enum PromptCacheReuseDecision: Equatable {

    /// Feed the whole prompt. The cache holds nothing worth reusing.
    case prefillAll

    /// The cache already represents a usable prefix. Feed only
    /// `promptTokens[suffixStart...]`; afterwards the cache represents
    /// `representedTokens`.
    ///
    /// `representedTokens` is not necessarily the rendered prompt. A response
    /// protocol may keep generated tokens that a cold template render cannot
    /// reproduce, in which case the ledger diverges from the render by design.
    case appendSuffix(suffixStart: Int, representedTokens: [Int])

    /// Feed a suffix into the main cache while discarding unusable speculative
    /// state (an ordinary draft cache or an MTP continuation). The current
    /// generation must use the main model only.
    case appendSuffixToMain(suffixStart: Int, representedTokens: [Int])

    /// The cache already represents a usable prefix, but this turn introduces
    /// new media, so a plain token slice would drop the payload that belongs
    /// to the suffix. Ask the model to split its own prepared input at
    /// `suffixStart`; afterwards the cache represents `representedTokens`.
    ///
    /// Only the model knows which part of a prepared input belongs to the
    /// suffix, so this decision -- like ``trimToCommonPrefix`` -- can fail while
    /// being applied. A model that declines the split must be downgraded to
    /// ``rebuild`` before prefilling.
    case appendMediaSuffix(suffixStart: Int, representedTokens: [Int])

    /// Rewind every cache by `trimCount` (down to `commonPrefixLength`), then
    /// feed `promptTokens[commonPrefixLength...]`.
    case trimToCommonPrefix(commonPrefixLength: Int, trimCount: Int)

    /// Rewind only the target cache, discard speculative state, and continue
    /// target-only from the common prefix.
    case trimToCommonPrefixMainOnly(commonPrefixLength: Int, trimCount: Int)

    /// The cache cannot be reconciled with this prompt. Discard it, drop any
    /// carried model state, and feed the whole prompt.
    case rebuild

    /// `true` when a non-empty cached prefix is carried into this turn.
    var reusesCachedPrefix: Bool {
        switch self {
        case .appendSuffix, .appendSuffixToMain, .appendMediaSuffix, .trimToCommonPrefix,
            .trimToCommonPrefixMainOnly:
            return true
        case .prefillAll, .rebuild:
            return false
        }
    }
}

/// The prompt-side facts of one turn that affect cache reuse.
struct PromptCacheTurn: Sendable {
    /// The full rendered prompt for this turn.
    var promptTokens: [Int]

    /// This turn's messages introduce new media, so the cached text prefix is
    /// no longer a valid prefix of the model's actual input.
    var carriesNewMedia: Bool = false

    /// The prepared input contains image/video/audio tensors, which the rewind
    /// path cannot account for.
    var carriesPreparedMedia: Bool = false

    /// The prepared input carries an explicit attention mask; a partial prefill
    /// would apply it against the wrong positions.
    var carriesAttentionMask: Bool = false

    /// Per-call model state (e.g. M-RoPE deltas) is carried across turns. Such
    /// state is anchored to a prefill and cannot be rewound.
    var carriesModelState: Bool = false

    /// This turn appends tool results to a transcript whose last assistant
    /// message issued tool calls, i.e. the generation loop is resuming rather
    /// than starting a new exchange.
    ///
    /// Response protocols that keep private per-turn state in the cache use
    /// this to recognize a restart they can splice onto.
    var isToolResultContinuation: Bool = false

    /// Generated tokens returned to the previous caller but not yet represented
    /// by the main cache. Speculative iterators can leave their final verifier
    /// sample in this state.
    var previousGenerationUncommittedTokens: [Int] = []

    /// Number of structured assistant tool-call messages represented by the
    /// rendered prompt. A protocol can compare this with raw control-token
    /// occurrences to reject ambiguous boundaries introduced by message text.
    var structuredToolCallCount: Int?

    /// The session is configured to use a draft model when possible. Protocol
    /// rules use this to avoid resuming from a private main-cache path with a
    /// missing or divergent draft cache.
    var usesSpeculativeDecoding: Bool = false

    /// The model can split a prepared input into a media-carrying suffix, so an
    /// append-only media turn has a way to reuse the cached prefix. The session
    /// reports the capability here rather than the policy inspecting the model,
    /// which keeps the decision table free of MLX and session types.
    ///
    /// Capability is not a guarantee: the split may still be declined for a
    /// specific input, which the caller handles when applying the decision.
    var canSplitPreparedMedia: Bool = false

    /// The tokens that end a turn for this model (its stop tokens). Used to find where a
    /// generated turn ends in the rendered prompt. Empty when not known.
    var turnEndTokens: Set<Int> = []
}

/// What speculative-cache reuse can safely accompany the authoritative main cache.
enum SpeculativeCacheReuseCapability: Sendable {
    /// Aligned speculative state can follow both suffix appends and target rewinds.
    case reusable

    /// Aligned speculative state can follow suffix appends, but a rewind must
    /// discard it and continue with the main cache only.
    case appendOnly

    /// Missing ordinary draft-model state can be reconstructed from the full prompt.
    case rebuildableFromPrompt

    /// Speculative state cannot be used, but the valid main cache may continue alone.
    case mainOnlyFallback

    /// Speculative state can neither be reused nor reconstructed for this prompt.
    case unavailable

    /// Whether an existing speculative continuation can be used without rebuilding it.
    var canContinueWithoutRebuild: Bool {
        switch self {
        case .reusable, .appendOnly:
            true
        case .rebuildableFromPrompt, .mainOnlyFallback, .unavailable:
            false
        }
    }
}

/// What the caches currently hold.
struct PromptCacheState: Sendable {
    /// Exact tokens the main cache represents, per the session's ledger. Empty
    /// means the ledger was invalidated and nothing may be spliced onto.
    var cachedTokens: [Int]

    /// Authoritative logical position of the main cache — the model-wide
    /// timeline maintained by ``KVCacheStorage``, not a per-entry offset.
    var processedTokenCount: Int

    /// The main cache's timeline agrees with the ledger length.
    var mainCacheIsAligned: Bool = false

    /// The valid operations available for the auxiliary speculative state.
    var speculativeReuseCapability: SpeculativeCacheReuseCapability = .unavailable

    /// Exact rewind limit across all participating layers.
    var maxTrimCount: Int = 0

    /// The parts of `cachedTokens` the model generated, in order: one range for each of its
    /// turns since the cache was last built from a prompt. The cache holds those turns as the
    /// model wrote them, which a render of the same conversation need not reproduce.
    var generatedSpans: [Range<Int>] = []
}

/// One reusability rule.
///
/// Returning `nil` means "this rule does not apply"; the policy then consults
/// the next rule. This is the extension point for response protocols whose
/// on-device token stream is not reproducible by a chat-template render.
protocol PromptCacheReuseRule: Sendable {
    func reuse(turn: PromptCacheTurn, cache: PromptCacheState) -> PromptCacheReuseDecision?
}

/// Decides how to reuse a KV cache across turns by consulting an ordered list
/// of rules.
///
/// The policy is free of MLX and session state, so the whole decision table can
/// be unit tested directly and the caller's only job is to *apply* the result.
struct PromptCacheReusePolicy: Sendable {

    /// Rules that apply to every model, in priority order.
    static let standardRules: [any PromptCacheReuseRule] = [
        ExtendCachedPrefixRule(),
        AppendOnlyMediaRule(),
        KeepGeneratedTurnsRule(),
        RewindToCommonPrefixRule(),
    ]

    private let rules: [any PromptCacheReuseRule]

    /// - Parameter protocolRules: rules contributed by the model's response
    ///   protocol. They are consulted before the standard rules, because a
    ///   protocol that keeps unrenderable state in the cache must claim the
    ///   turn before generic prefix comparison is attempted on token streams
    ///   that are not comparable.
    init(protocolRules: [any PromptCacheReuseRule] = []) {
        self.rules = protocolRules + Self.standardRules
    }

    func decide(turn: PromptCacheTurn, cache: PromptCacheState) -> PromptCacheReuseDecision {
        for rule in rules {
            if let decision = rule.reuse(turn: turn, cache: cache) {
                return decision
            }
        }
        return .rebuild
    }
}

// MARK: - Standard rules

/// Appends the trailing tokens when the prompt strictly extends the cache.
struct ExtendCachedPrefixRule: PromptCacheReuseRule {
    func reuse(turn: PromptCacheTurn, cache: PromptCacheState) -> PromptCacheReuseDecision? {
        guard !cache.cachedTokens.isEmpty,
            cache.mainCacheIsAligned,
            !turn.carriesNewMedia,
            !turn.carriesAttentionMask,
            turn.promptTokens.count > cache.cachedTokens.count,
            turn.promptTokens.starts(with: cache.cachedTokens)
        else {
            return nil
        }

        if turn.usesSpeculativeDecoding {
            switch cache.speculativeReuseCapability {
            case .reusable, .appendOnly, .rebuildableFromPrompt:
                return .appendSuffix(
                    suffixStart: cache.cachedTokens.count,
                    representedTokens: turn.promptTokens)
            case .mainOnlyFallback:
                return .appendSuffixToMain(
                    suffixStart: cache.cachedTokens.count,
                    representedTokens: turn.promptTokens)
            case .unavailable:
                return nil
            }
        }

        return .appendSuffix(
            suffixStart: cache.cachedTokens.count, representedTokens: turn.promptTokens)
    }
}

/// Appends the trailing tokens when a turn adds media to an otherwise unchanged
/// transcript.
///
/// An append-only media turn extends the cached prefix exactly as a text turn
/// does, so ``ExtendCachedPrefixRule`` would accept it but for its
/// `carriesNewMedia` guard: a plain token slice drops the media payload that
/// belongs to the suffix. The split itself is the model's job, so this rule only
/// fires when the session reports the model can perform it.
///
/// Unlike ``ExtendCachedPrefixRule`` this rule does **not** require the absence
/// of an attention mask. A VL processor pairs media with an all-ones mask as a
/// matter of course, so refusing masks here would disable the path for exactly
/// the inputs it exists to serve. Distinguishing that benign mask from a real
/// padding mask needs the model's own layout knowledge, so the check belongs to
/// the splitter, which refuses anything that is not all-ones.
struct AppendOnlyMediaRule: PromptCacheReuseRule {
    func reuse(turn: PromptCacheTurn, cache: PromptCacheState) -> PromptCacheReuseDecision? {
        guard turn.carriesNewMedia,
            turn.canSplitPreparedMedia,
            !turn.usesSpeculativeDecoding,
            !cache.cachedTokens.isEmpty,
            cache.mainCacheIsAligned,
            turn.promptTokens.count > cache.cachedTokens.count,
            turn.promptTokens.starts(with: cache.cachedTokens)
        else {
            return nil
        }

        return .appendMediaSuffix(
            suffixStart: cache.cachedTokens.count, representedTokens: turn.promptTokens)
    }
}

/// Carries on from a cache whose generated turns a render does not reproduce exactly.
///
/// A cache holds each of the model's own turns as the model wrote it. The template's
/// render of the same turn can differ: a tool call's arguments in another order, the
/// reasoning left out or spaced differently. A cache that can rewind goes back to where
/// the two part and reads the render's version (``RewindToCommonPrefixRule``). One that
/// cannot (a recurrent or hybrid model) would read the whole prompt again, at every such
/// turn: on a prompt of 6,000 tokens that is most of a minute for each step of a tool loop.
///
/// This rule keeps the model's own version instead. Everything outside the generated turns
/// must be in the prompt token for token; each generated turn is matched to the turn that
/// opens the same way in the prompt and runs to its end; and what the prompt adds after the
/// last of them is fed as a suffix. It applies only when rewinding is not possible, so a
/// model that can rewind behaves as before.
struct KeepGeneratedTurnsRule: PromptCacheReuseRule {
    /// Fewest tokens of a turn's opening (its role header) that must match for the turn in
    /// the prompt to count as the one the cache holds.
    static let openingTokens = 2

    /// Development aid: `HARNESS_KEEP_TURNS=0` switches the rule off, to measure what it saves.
    private static let isOn = ProcessInfo.processInfo.environment["HARNESS_KEEP_TURNS"] != "0"

    func reuse(turn: PromptCacheTurn, cache: PromptCacheState) -> PromptCacheReuseDecision? {
        guard Self.isOn else { return nil }
        let cached = cache.cachedTokens
        let prompt = turn.promptTokens
        let ends = turn.turnEndTokens
        guard !cached.isEmpty, cache.mainCacheIsAligned,
            !turn.carriesNewMedia, !turn.carriesAttentionMask, !turn.usesSpeculativeDecoding,
            turn.previousGenerationUncommittedTokens.isEmpty,
            !ends.isEmpty, !cache.generatedSpans.isEmpty
        else {
            return nil
        }

        // A cache that can go back to where the two part reads the render's version.
        let common = zip(prompt, cached).prefix { $0 == $1 }.count
        guard common < cached.count, cached.count - common > cache.maxTrimCount else {
            return nil
        }

        var i = 0  // in `cached`
        var j = 0  // in `prompt`
        for span in cache.generatedSpans {
            guard !span.isEmpty, span.lowerBound >= i, span.upperBound <= cached.count else {
                return nil
            }
            // The turn the span belongs to starts after the last end of turn before it.
            let turnStart =
                cached[i ..< span.lowerBound].lastIndex { ends.contains($0) }.map { $0 + 1 } ?? i
            // Everything before that turn is in both, token for token.
            let before = turnStart - i
            guard j + before <= prompt.count,
                cached[i ..< turnStart].elementsEqual(prompt[j ..< (j + before)])
            else {
                return nil
            }
            j += before
            // The turn opens the same way in both: a turn the template left out, or another
            // turn in its place, is not one to skip over.
            let opening = min(4, span.lowerBound - turnStart)
            guard opening >= Self.openingTokens, j + opening <= prompt.count,
                cached[turnStart ..< (turnStart + opening)].elementsEqual(
                    prompt[j ..< (j + opening)])
            else {
                return nil
            }
            // What the model wrote has an end of turn only as its last token, when it
            // stopped of its own accord.
            let endsItself = ends.contains(cached[span.upperBound - 1])
            guard !cached[span.lowerBound ..< (span.upperBound - 1)].contains(where: ends.contains)
            else {
                return nil
            }
            // In the prompt the turn runs to the first end of turn.
            guard let end = prompt[j...].firstIndex(where: ends.contains) else { return nil }
            i = span.upperBound
            j = endsItself ? end + 1 : end
        }

        // What was fed after the last generated turn must be in the prompt too, and the
        // prompt must add something.
        let after = cached.count - i
        guard j + after < prompt.count, cached[i...].elementsEqual(prompt[j ..< (j + after)])
        else {
            return nil
        }
        let suffixStart = j + after

        // The cache now holds more than a render would (reasoning the template drops from
        // earlier turns, say). A little is the price of not reading everything again; a lot
        // is context better spent, so the prompt is read afresh.
        let kept = cached.count - suffixStart
        guard kept <= max(1024, prompt.count / 4) else { return nil }

        return .appendSuffix(
            suffixStart: suffixStart, representedTokens: cached + prompt[suffixStart...])
    }
}

/// Rewinds to the longest common prefix, or rebuilds when that is unsafe.
///
/// This rule always decides, so it is the natural terminal rule.
struct RewindToCommonPrefixRule: PromptCacheReuseRule {
    func reuse(turn: PromptCacheTurn, cache: PromptCacheState) -> PromptCacheReuseDecision? {
        // A cache at position zero has nothing to rewind and nothing to
        // invalidate, so the prompt is simply prefilled into it.
        guard cache.processedTokenCount != 0 else {
            return .prefillAll
        }

        let commonPrefixLength = zip(turn.promptTokens, cache.cachedTokens)
            .prefix { $0 == $1 }
            .count
        let trimCount = cache.cachedTokens.count - commonPrefixLength

        let canRewind =
            commonPrefixLength > 0
            && commonPrefixLength < turn.promptTokens.count
            && trimCount > 0
            && cache.mainCacheIsAligned
            && trimCount <= cache.maxTrimCount
            && !turn.carriesNewMedia
            && !turn.carriesPreparedMedia
            && !turn.carriesAttentionMask
            && !turn.carriesModelState

        guard canRewind else {
            // The template changed an already-cached portion of the transcript,
            // or this input carries state/media that cannot be rewound safely.
            // Rebuild rather than combining a mismatched prompt with stale
            // model state.
            return .rebuild
        }

        if turn.usesSpeculativeDecoding {
            switch cache.speculativeReuseCapability {
            case .reusable, .rebuildableFromPrompt:
                return .trimToCommonPrefix(
                    commonPrefixLength: commonPrefixLength, trimCount: trimCount)
            case .appendOnly, .mainOnlyFallback:
                return .trimToCommonPrefixMainOnly(
                    commonPrefixLength: commonPrefixLength, trimCount: trimCount)
            case .unavailable:
                return .rebuild
            }
        }

        return .trimToCommonPrefix(commonPrefixLength: commonPrefixLength, trimCount: trimCount)
    }
}
