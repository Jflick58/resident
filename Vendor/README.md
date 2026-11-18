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
| Weights used straight from a mapped file | `MLXLMCommon/PagedWeights.swift`, `AlignedWeights.swift`, `Load.swift` | A model larger than the app's memory limit can run: mapped weights are not charged to the app. The weights file is rearranged in place for it (large tensors moved to page boundaries), so there is one copy on disk. It is mapped shared and read only, so the GPU reads the file's own pages: through a private mapping the system gives the GPU its own copy of every page it touches, which it can compress but never drop, and a 27B on a 12 GB phone was closed by the system on its second reply. What the model has read is pinned while it is at work (`WeightMapping.hold()`), because shared pages are the first thing a system short of memory takes: unpinned, a 27B's second reply on that phone had not started after 70 seconds of reading its weights back |
| A saved copy of a prompt's opening | `ChatSession.readSharedOpening`, `saveCacheWithTokens`, `init(savedCache:)` | A new chat starts from the instructions and tools already read, on disk between runs |
| Generated turns kept as the model wrote them | `KeepGeneratedTurnsRule` in `PromptCacheReusePolicy.swift`, `generatedSpans` in `ChatSession` | A model whose cache cannot rewind (Qwen 3.5, Bonsai, LFM) read the whole prompt again after any turn the template rendered differently from how it was written, such as a tool call with its arguments in another order |
| One rotation for layers given the same input | `HadamardQuantizedLinear.rotatedInput` in `HadamardQuantized.swift` | A Bonsai pack has one sign vector for each width, and layers side by side each rotated the same input for themselves. Shared, a token takes 3 to 6% less time |
| A ternary layer computed without its biases | `HadamardQuantizedLinear.sharesScales`, the `resident_*` Metal kernels | In a ternary pack every bias is its scale negated, a tenth of the file that has to stay in memory to no purpose: 420 MB of a 27B model. Switched on for a mapped model that fills the device's memory, at a cost of a few per cent of speed |
| Tools declared in the conversation | `ChatSession.laterTools` | A call to a tool the caller declared in a message, not through the template, is accepted. Declaring it through the template changes the prompt from its first tokens |

Once the two pull requests are in a release and these are upstream or no longer
needed, delete this folder and point `HarnessMLX/Package.swift` back at the
library.
