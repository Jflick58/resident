# Vendored code

## mlx-swift-lm

A copy of [ml-explore/mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm)
at `6352907` (10 November 2026) with two open pull requests merged in, because
the app needs models that the library does not load yet:

| Pull request | Adds | Merged from |
|---|---|---|
| [#781](https://github.com/ml-explore/mlx-swift-lm/pull/781) | LFM3-VL (image input for Liquid's LFM3) | `alvarogarciapiz/mlx-swift-lm` at `0c0c07a` |
| [#630](https://github.com/ml-explore/mlx-swift-lm/pull/630) | Bonsai 2 (PrismML's ternary models, `prism_hadamard_qwen35`) | `spokvulcan/mlx-swift-lm` at `a3596e4` |

The two merged without conflicts and nothing else was changed. Once both are
in a release, delete this folder and point `HarnessMLX/Package.swift` back at
the library.
