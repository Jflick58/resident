# Vendored code

## mlx-swift-lm

A copy of [ml-explore/mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm)
at `6352907` (10 November 2026) with two open pull requests merged in, because
the app needs models that the library does not load yet:

| Pull request | Adds | Merged from |
|---|---|---|
| [#781](https://github.com/ml-explore/mlx-swift-lm/pull/781) | LFM3-VL (image input for Liquid's LFM3) | `alvarogarciapiz/mlx-swift-lm` at `0c0c07a` |
| [#630](https://github.com/ml-explore/mlx-swift-lm/pull/630) | Bonsai 2 (PrismML's ternary models, `prism_hadamard_qwen35`) | `spokvulcan/mlx-swift-lm` at `a3596e4` |

The two merged without conflicts.

### Changes made here

The app's own changes to the library, each of which would have to go upstream
(or be dropped) before the folder can be deleted:

| Change | Where | Why |
|---|---|---|
| Weights used straight from a mapped file | `MLXLMCommon/PagedWeights.swift`, `AlignedWeights.swift`, `Load.swift` | A model larger than the app's memory limit can run: mapped weights are not charged to the app. The weights file is rearranged in place for it (large tensors moved to page boundaries), so there is one copy on disk |
| A saved copy of a prompt's opening | `ChatSession.readSharedOpening`, `saveCacheWithTokens`, `init(savedCache:)` | A new chat starts from the instructions and tools already read, on disk between runs |
| Generated turns kept as the model wrote them | `KeepGeneratedTurnsRule` in `PromptCacheReusePolicy.swift`, `generatedSpans` in `ChatSession` | A model whose cache cannot rewind (Qwen 3.5, Bonsai, LFM) read the whole prompt again after any turn the template rendered differently from how it was written, such as a tool call with its arguments in another order |
| Tools declared in the conversation | `ChatSession.laterTools` | A call to a tool the caller declared in a message, not through the template, is accepted. Declaring it through the template changes the prompt from its first tokens |

Once the two pull requests are in a release and these are upstream or no longer
needed, delete this folder and point `HarnessMLX/Package.swift` back at the
library.
