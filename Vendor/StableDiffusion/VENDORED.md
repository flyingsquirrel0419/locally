# Vendored: apple/ml-stable-diffusion

Upstream: https://github.com/apple/ml-stable-diffusion
Commit:   ea2805dc1945be20561c77e5f6d1d9a5a637cda2
License:  MIT (see LICENSE.md, unchanged)

## Why vendored

At commit ea2805dc the upstream Package.swift pins
`swift-transformers` to `exact: "0.1.8"`, which conflicts with the app's
pin of `exact: 1.3.4` (required by mlx-swift-lm 3.31.4), so Xcode SPM
resolution fails. Only the Stable Diffusion 3 support uses
swift-transformers in the upstream library, and Locally's DiffusionRuntime
never uses SD3 — so the SD3 sources were dropped and the dependency
removed.

## Files removed (upstream path swift/StableDiffusion/...)

- pipeline/StableDiffusion3Pipeline.swift
- pipeline/StableDiffusion3Pipeline+Resources.swift
- pipeline/TextEncoderT5.swift            (imports Transformers)
- pipeline/MultiModalDiffusionTransformer.swift
- pipeline/DiscreteFlowScheduler.swift    (SD3 rectified-flow scheduler)
- tokenizer/T5Tokenizer.swift             (imports Transformers)
- swift/StableDiffusionCLI/               (not needed; pulls in swift-argument-parser)
- swift/StableDiffusionTests/             (upstream tests, not vendored)

## Files changed

- StableDiffusionPipeline.swift: removed the `.discreteFlowScheduler` case
  from `StableDiffusionScheduler` and its switch arm in `generateImages`.
- StableDiffusionXLPipeline.swift: removed the `.discreteFlowScheduler`
  switch arm in `generateImages`.
- StableDiffusionPipeline.Configuration.swift: removed the
  `schedulerTimestepShift` property (only consumed by DiscreteFlowScheduler).
- Package.swift rewritten: local package, iOS 17 / macOS 14, no
  dependencies (swift-transformers and swift-argument-parser dropped with
  the removed sources).

All other files are byte-identical to upstream at the commit above.
