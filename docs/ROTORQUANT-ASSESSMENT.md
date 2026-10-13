# Assessment: can RotorQuant / PlanarQuant / IsoQuant help our KV cache?

**Verdict: not as a port, no. Watch mainline instead.**

This was investigated in response to a question about
[`scrya-com/rotorquant`](https://github.com/scrya-com/rotorquant). The short version: the
idea is sound and the direction is right, but the implementation cannot be merged into
this stack, and the problem it solves is already solved here by other means.

## What it is

A research repository for KV cache compression: rotate the cache vectors with a
block-diagonal transform before scalar quantization, so the quantization error is lower
than quantizing the raw vectors. The repo itself is a Python/Triton package. The llama.cpp
implementation it advertises lives in someone else's fork, reached from its own Quick Start:

```
johndpope/llama-cpp-turboquant  ->  TheTom/llama-cpp-turboquant  ->  llama.cpp
```

It introduces new cache types: `planar3`, `planar4`, `iso3`, `iso4`, `turbo2`, `turbo3`,
`turbo4`.

## The blocker: two competing rotation schemes in the same file

This is the decisive problem, and it is not about effort.

PrismML's fork already rotates the K cache before quantizing it. That is the mechanism
`--kv-mean-center` calibrates against, and this project uses it. It lives in:

| File | Symbol |
|---|---|
| `src/llama-kv-cache.cpp` | `attn_rot_k`, `attn_rot_v`, `LLAMA_ATTN_ROT_DISABLE` |
| `src/llama-kv-cache.h` | the same fields |

The rotorquant branch hooks the **same two files** with a **different** scheme:

| File | Symbol |
|---|---|
| `src/llama-kv-cache.h` | `turbo_rotation`, `turbo_rotation_inv` (128x128 matrices) |
| `src/llama-kv-cache.h` | `turbo_innerq_scale_inv` |
| `src/llama-kv-cache.cpp` | `GGML_TYPE_TURBO*_0`, `GGML_TYPE_PLANAR*_0`, `GGML_TYPE_ISO*_0` |
| `src/llama-kv-cache.cpp` | per-layer "adaptive mode" boundary heuristics |

Both rotate the K cache before quantization, both carry rotation matrices, both hook the
cache-write path, and both feed the flash-attention kernels. Merging them is not additive
work; it means reconciling two implementations of the same idea, on a codebase where one
of them is already shipped and already calibrated.

## The size of the change

`johndpope/llama-cpp-turboquant`, `feature/planarquant-kv-cache` against that fork's
`master`:

| | |
|---|---|
| Commits ahead | **171** |
| Files changed | **158** |
| Lines added | **24,548** |
| Lines removed | 533 |

That is the whole branch, and it carries unrelated drift (multimodal `deepseek-ocr`
support, Hugging Face download changes, Snapdragon scripts, Android CI). Isolating just
the KV work still leaves, at minimum:

**New quantization implementations**

| File | Lines |
|---|---|
| `ggml/src/ggml-turbo-quant.c` | +624 |
| `ggml/src/ggml-iso-quant.c` | +183 |
| `ggml/src/ggml-planar-quant.c` | +172 |
| `ggml/src/ggml-iso4-quant.c` | +131 |
| `ggml/src/ggml-planar4-quant.c` | +117 |

**Generated rotation data**

| File | Lines |
|---|---|
| `src/turbo-rotation-data.h` | +4,103 |
| `ggml/src/ggml-metal/turbo-matrices.h` | +8,207 |
| `src/turbo-rotation-data-32.h` | +71 |

**CUDA**

`fattn-common.cuh` +830, `set-rows.cu` +954, `turbo-quant.cuh` +421, `cpy-planar-iso.cu`
+320, `set-rows-planar-iso.cuh` +239, `turbo-wht.cu` +174, `fattn.cu` +145,
`dequantize.cuh` +136, `fattn-vec.cuh` +106, plus `vecdotq.cuh`, `ggml-cuda.cu`,
`mmvq.cu`, `convert.cu`, `cpy.cu`, `turbo-innerq.*`, vendor headers, CMake changes and
roughly **50 new flash-attention template-instance files**.

**Metal**

`ggml-metal.metal` +2,312 / -214, plus device and ops changes.

**CPU, OpenCL and core ggml**

`ggml-cpu/ops.cpp` +157, `ggml-cpu/ggml-cpu.c` +104, `ggml-common.h` +103, `ggml.c` +101,
`ggml-quants.h` +31, `ggml-opencl.cpp` +26, CMake changes.

**llama.cpp runtime and type registry**

`llama-kv-cache.cpp` +375 / -32, `llama-model.cpp` +138 / -19, `llama-graph.cpp` +122,
`llama-context.cpp` +52, `llama-memory-hybrid.*`, `llama-arch.*`, plus `gguf-py` changes
so the new types round-trip through GGUF.

It also adds five-plus new GGML types, which ripple through `type_traits`, the block
definitions, every backend's convert/copy/set-rows path, and the model loader.

**And it would need rebasing.** The branch last moved **2026-05-07**; the pinned PrismML
build is **2026-10-10**. Five months of ggml type-system, flash-attention and KV-cache
drift sit in between.

**And it is unvalidated on AMD.** Every benchmark in the README is RTX 5090 or M4. The
branch touches `vendors/hip.h` and `ggml-hip/CMakeLists.txt`, so HIP is at least partly
wired, but no ROCm results are reported. This project runs on ROCm.

## Claims worth verifying before anyone invests

1. **"3-bit symmetric, 10.3x compression."** Three bits against f16 is 16/3 = **5.3x**.
   The repo's own VRAM table does show 10.3x (32K: 1152 MB to 112 MB), which implies about
   **1.55 effective bits**, inconsistent with "3-bit".
2. **The VRAM table looks like the wrong model.** 288 MB at 8K is 36 KB/token, which
   matches a 3B model (36 layers x 2 KV heads x 128 dim x 2 bytes). It sits under a
   *Llama 3.1 8B* headline, which would be roughly 128 KB/token, about 4x larger.
3. **The baseline is the wrong one.** It compares against TurboQuant, not against
   llama.cpp's built-in `q8_0` / `q4_0` cache types, which is the actual alternative.
4. **Self-published paper, AI-assisted repo.** The paper is hosted on the author's own
   site rather than arXiv or a venue, and the repository contains `CLAUDE.md` and
   `grok_prompt.md`.

None of that makes the technique wrong. The underlying idea - rotate before quantizing,
and use cheap block-diagonal transforms instead of a full Hadamard transform - is
legitimate and sits in the same family as QuaRot, SpinQuant and TurboQuant. It is the
evidence and the integration readiness that do not hold up.

## What this project uses instead

Both are already in the pinned build, need no new code, and were measured here:

| Configuration | KV cache on the 8B at 65536 | vs f16 |
|---|---|---|
| `f16` / `f16` | 9216 MiB (9.0 GB) | 1.00x |
| `q8_0` / `q8_0` (**default**) | 4896 MiB (4.8 GB) | 1.88x |
| `q4_0` K + `q8_0` V + `--kv-mean-center` | 3744 MiB (3.66 GB) | 2.46x |
| `q4_0` / `q4_0` | 2592 MiB (2.5 GB) | 3.56x |

With the fork's own measured quality for the centred configuration: logit KLD 0.00111
against 0.00144 uncentered, on a hybrid-attention model with a `q4_0` K cache.

So the practical ceiling available today is **3.56x**, or **2.46x with quality recovered**,
against a claimed 10.3x that does not reconcile with its own bit width and would require
everything above to obtain.

See [HARDWARE.md](HARDWARE.md#vram-and-ram) for the full measurements and
[SOURCE-BUILD.md](SOURCE-BUILD.md) for the source-build path.

## Recommendation

**Watch mainline, do not port.** If the planar/iso cache types land in upstream
llama.cpp - and the fact that this is built on a llama.cpp fork suggests that is the
intent - then PrismML's fork inherits them on its next sync, and they become a one-flag
change exactly like `--cache-type-k q8_0` is today:

```bash
BONSAI_KV_TYPE=planar3 ./scripts/start-server.sh
```

That is the version worth waiting for, and it costs nothing to wait.

## If someone still wants to try

The honest scope, so nobody starts this expecting a patch:

1. Separate the KV work from the 171-commit branch, which carries unrelated multimodal
   and tooling drift.
2. Decide which rotation scheme survives, since PrismML already ships one. Expect this to
   be the hardest part, because `--kv-mean-center` is calibrated against PrismML's basis.
3. Rebase ~3,000 lines of kernels onto a five-month-newer ggml, across CPU, CUDA and
   Metal, and wire ROCm, which is unvalidated upstream.
4. Rebuild and re-validate the calibration basis if PrismML's rotation is kept.

That is a multi-month project with a design conflict at its centre, not a port.
