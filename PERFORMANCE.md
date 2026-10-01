# Performance — Linux x86 CPU baseline

Measured on the development container, NOT an iPhone. Numbers here are a
lower bound for a desktop-class CPU with only 2 cores and 3.8 GB RAM
available to the process.

## Machine

- Linux 6.8.0-138-generic, x86_64
- CPU: AMD Ryzen 9 9900X (12-core host), container limited to 2 cores
- RAM: 3.8 GB available
- Swift 6.1.2, llama.cpp pinned at v0.5.0 (commit `7fe450e`), CPU-only build,
  GGML_NATIVE=OFF, no `-march` flags (x86-64 baseline)
- Model: `SmolLM2-135M-Instruct-Q4_K_M.gguf` (98.87 MiB, 134.52 M params)
- Commit under test: `69ea48d9a7b8eecfcee5ba9d4a7f30387ee5e41e` + working-tree
  changes from the perf fix (see DECISIONS.md "Week 6b")

## llama.cpp reference baseline

Commands run from a scratch build configured with the same flags as
`scripts/build-llama-linux.sh`, plus `-DLLAMA_BUILD_TOOLS=ON
-DLLAMA_BUILD_EXAMPLES=ON` to get the bench/simple binaries:

```sh
cmake -S /root/locally/.deps/llama.cpp -B $SCRATCH/llama-bench-build \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON -DLLAMA_CURL=OFF \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=ON -DLLAMA_BUILD_TOOLS=ON \
  -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_APP=OFF -DGGML_NATIVE=OFF
cmake --build $SCRATCH/llama-bench-build --target llama-bench llama-simple -j2
```

```sh
$SCRATCH/llama-bench-build/bin/llama-bench \
  -m /root/locally/.deps/models/SmolLM2-135M-Instruct-Q4_K_M.gguf \
  -t 2 -p 16 -n 32
```

Result:

| test | t/s (mean) |
|------|-----------:|
| pp16 | 578.39 ± 45.87 |
| tg32 | 148.10 ± 29.56 |

`llama-simple` at `-t 2 -n 64 "Hello"` reports `eval time = 535.93 ms /
31 runs` → 57.84 tok/s for one-shot interactive decode, slower than bench
because bench's tg loop bypasses the sampler chain. `llama-simple`
measured the sampler chain apply at ~1.5 ms over 64 tokens (~0.02 ms per
token), so the difference between bench (148 t/s) and simple (58 t/s) is
not sampling — it is bench's tighter loop.

The GGUF runtime therefore treats llama-bench's `tg32 = 148 t/s` as the
theoretical ceiling and llama-simple's ~58 t/s as the floor a faithful
Swift port must clear. Any number between them is healthy.

## GGUFRuntime: before vs after

Same machine, same model, same prompt ("What is the capital of France?
Answer with one word."), greedy decode, maxTokens=32, default context.

Debug build (`swift build`, no `-c`):

| Build | TTFT | tok/s | Generated |
|-------|-----:|------:|----------:|
| Before (commit `69ea48d`, sampler chain rebuilt per token, 4 actor hops per token) | 0.477 s | 2.68 | 7 |
| After  | 0.075–0.10 s | 114.8–148.1 | 7 |

Release build (`swift build -c release`), after fix:

| Metric | Value |
|--------|------:|
| TTFT   | 0.077 s |
| tok/s  | 148.10 (matches llama-bench tg32 mean exactly) |
| Peak RSS | 408 MB (process-level, /proc/self/statm; approximate) |

Long-generation regression test (256 tokens, greedy, `contextLength: 1024`):

| Build | tok/s sustained over 256 tokens |
|-------|--------------------------------:|
| Debug, after fix   | 98.6 |
| Release, after fix | 106.3 |

No slowdown cliff: the per-token rate at token 256 is within noise of the
rate at token 1 (the test fails the run if generation stalls).

### Re-measurement, 2026-10-02 (with thermal-pacing hook added)

Re-run on the same container after the Week-13 thermal-pacing change
(`GenerationPacer`, no-op by default in the package). The decode loop now
awaits `pacer.pace()` per token; the no-op cost is within noise.

Short run (prompt as above, greedy, maxTokens=32, release):

| Metric | Value |
|--------|------:|
| Load time | 0.062 s |
| TTFT   | 0.072 s |
| tok/s  | 120.1 (7 generated tokens) |
| Peak RSS | 364 MB (process-level, approximate) |

Long run (`testLongGenerationHasNoSlowdownCliff`, release): 256 tokens
sustained at **130.4 tok/s**, peak 215 MB. All 5 `LiveLlamaTests` passed in
release. Run-to-run variance on this shared 2-core box is ±30%, so 120–148
tok/s short-run is the healthy band; no regression from the pacer.

### Commands

```sh
swift build -j 2
LOCALLY_LIVE_LLAMA=1 swift test -j 2 --filter LiveLlamaTests
swift build -c release -j 2
LOCALLY_LIVE_LLAMA=1 swift test -c release -j 2 --filter LiveLlamaTests
```

### What was wrong (root causes)

1. **Sampler chain rebuilt on every token.** `sampleNext` used to call
   `llama_sampler_chain_init`, append four sampler stages, sample, then
   `llama_sampler_free` — for every generated token. That per-token
   setup/teardown dominated the budget for a 135 M model on 2 cores.
   Fix: one chain per decode context, rebuilt only when sampling
   parameters change; freed in `endContext()`.
2. **Four actor hops per token.** The decode loop awaited
   `sampleNext`, `isEndOfGeneration`, `tokenPiece`, and `decode` —
   four `LlamaBridge` actor round-trips per token. Fix: a single
   `generateNext` method that samples, checks EOG, decodes the token
   back, and returns the piece bytes in one hop.
3. **Thread count taken from `processorCount`.** That is logical cores;
   on cgroup-limited containers it can oversubscribe. Fix:
   `activeProcessorCount`, matching llama-bench's `-t 2` baseline.

### What was already fine

- One-token `llama_batch_get_one` per decode step (no sequence re-decode).
- No per-token O(vocab) Swift work; logits stay in C memory.
- Piece detokenization is a single `llama_token_to_piece` call into a
  stack buffer.
- Prompt is decoded once via one batched `llama_decode`.

### Measurement notes

- `tokensPerSecond` counts generated tokens over per-token decode time
  (sample + decode), excluding prompt eval — same convention as
  llama-bench's tg metric. Prompt eval is reported via TTFT
  (`promptStart → first non-EOG token`).
- The 2-core box is shared with other jobs; runs vary by ±30%. The
  release-build 148 t/s match to llama-bench's mean is partly luck
  (same compute, same thread count, sampler in greedy mode adds
  negligible time).
- `peakMemoryBytes` is process RSS, not a per-model counter — llama.cpp
  does not expose one through the C API. Labelled approximate in the
  source and in `InferenceMetadata.peakMemoryBytes`'s docstring.

## iPhone performance: not yet measured

No on-device numbers exist yet. Everything above is a Linux x86 CPU
baseline; an iPhone (Metal GPU for MLX/VLM/diffusion, ARM CPU for GGUF)
will produce materially different numbers, and none should be extrapolated
from this page.

How to measure on device:

1. Build and run the app on a physical iPhone (Xcode 16+, iOS 17+;
   simulator has no Metal and is not representative).
2. Run the Home-tab benchmark once so `CompatibilityProvider` has a real
   device sample (it persists across relaunch).
3. Load a model in the Playground and generate. Every run's
   `.completed` event carries `InferenceMetadata` — TTFT, tokens/sec,
   generated-token count, peak memory — shown in the playground after
   generation and returned to callers of `AIRuntime.run`.
4. Record those values per device class (chip, RAM) and per runtime
   (GGUF vs MLX) here before quoting any iPhone performance claim.
