# Hardware and backends

`scripts/detect.sh` probes the machine and writes the result to `.state/detect.env`.
Every other script reads that file, so detection runs once and everything agrees.

```bash
./scripts/detect.sh          # human-readable
./scripts/detect.sh --json   # machine-readable
```

## What it looks at

| Signal | Source |
|---|---|
| OS and architecture | `uname -s`, `uname -m` |
| AVX512 | `avx512f` in `/proc/cpuinfo` |
| GPU vendor | `lspci` display devices |
| VRAM | `/sys/class/drm/card*/device/mem_info_vram_total`, else `nvidia-smi` |
| System RAM | `MemTotal` in `/proc/meminfo` |
| ROCm | `/opt/rocm*`, `rocm_agent_enumerator` for the gfx id |
| CUDA | `nvidia-smi` first, `nvcc` as a fallback |
| Vulkan | `vulkaninfo --summary` |

## Backend selection

Order of preference, taking the first option that has a prebuilt asset for this OS and
architecture:

1. **CUDA** - NVIDIA GPU with a driver reporting a CUDA version
2. **ROCm/HIP** - AMD GPU with ROCm 7.2 or newer
3. **Vulkan** - any Vulkan 1.2+ runtime
4. **CPU** - always available

Notes on the edges:

- A CUDA runtime on **arm64** has no prebuilt asset, so detection falls through rather
  than failing later. Same for ROCm on arm64.
- **ROCm older than 7.2** does not match the pinned prebuilt. Detection warns and falls
  back to Vulkan if present, else CPU. Use `./scripts/build-from-source.sh` for a
  matching HIP build.
- **No AVX512** is not a problem. It only affects the CPU 1-bit kernel, which falls
  back to a slower scalar path. You lose speed, not correctness.
- Force a choice with `BACKEND=cpu|vulkan|cuda|rocm`.

## Asset mapping

Assets come from [PrismML-Eng/llama.cpp releases](https://github.com/PrismML-Eng/llama.cpp/releases),
pinned in `scripts/lib/common.sh` as `PRISM_RELEASE`.

| Detected | Asset |
|---|---|
| AMD + ROCm 7.2, x64 | `...-bin-ubuntu-rocm-7.2-x64.tar.gz` |
| NVIDIA + CUDA 13.3+, x64 | `...-bin-linux-cuda-13.3-x64.tar.gz` |
| NVIDIA + CUDA 12.8+, x64 | `...-bin-linux-cuda-12.8-x64.tar.gz` |
| NVIDIA + CUDA 12.x, x64 | `...-bin-linux-cuda-12.4-x64.tar.gz` |
| Vulkan, x64 | `...-bin-ubuntu-vulkan-x64.tar.gz` |
| Vulkan, arm64 | `...-bin-ubuntu-vulkan-arm64.tar.gz` |
| CPU, x64 | `...-bin-ubuntu-x64.tar.gz` |
| CPU, arm64 | `...-bin-ubuntu-arm64.tar.gz` |

## AMD without ROCm

You do not have to install ROCm. An AMD card with no ROCm at all is detected as
**Vulkan** and gets the Vulkan prebuilt, which needs only a Vulkan 1.2 driver:

```bash
BACKEND=vulkan ./scripts/setup.sh
```

Detection does this by itself when ROCm is absent, and falls back to CPU if there is no
Vulkan runtime either. The trade is speed and format support:

- Vulkan has only **partial** `PQ2_0` / `PTQ1_0` support; prefer `Q2_0_g64` or `Q1_0`.
- A HIP build is faster where it works. One measurement on an RTX 2070 Super put the CUDA
  build 40% ahead of PrismML's Vulkan build on the same card, so expect a real gap rather
  than a rounding difference.

For a colleague with a Radeon card and no ROCm, Vulkan is the difference between "works
after installing a driver" and "works after installing a 4 GB toolkit and matching the
gfx target".

## ROCm and gfx targets

HIP binaries are compiled for a fixed list of gfx targets. Detection compares the
reported target against that list:

```
gfx908 gfx90a gfx942 gfx1030 gfx1031 gfx1032 gfx1100 gfx1101 gfx1102 gfx1150 gfx1151 gfx1200 gfx1201
```

If your target is in the list, nothing extra is needed. If it is not, you get a warning
and two options:

1. Build from source, which compiles for your exact target:
   `./scripts/build-from-source.sh`
2. Try an override, telling the runtime to report a target the binary was built for:

   ```bash
   HSA_OVERRIDE_GFX_VERSION=11.0.0 ./scripts/start-server.sh
   ```

   The correct value is the closest supported target. This is a workaround, not a fix.

The override is **never** applied automatically and never hardcoded. `start-server.sh`
and `install-service.sh` only pass it through when you have set it yourself.

## VRAM and RAM

### The KV cache dominates at long context

The intuitive model - "a 1.7B is tiny, so it fits anywhere" - is wrong here, and it is
the single most common surprise.

The KV cache scales with **context length**, not model size. On the 8B at the 65536
tokens Hermes requires, measured with `llama_kv_cache: size = ...`:

| Cache type | KV cache at 65536 | vs f16 | 8B total |
|---|---|---|---|
| `f16` | 9216 MiB (9.0 GB) | 1.00x | ~11.0 GB |
| **`q8_0` (default)** | **4896 MiB (4.8 GB)** | **1.88x smaller** | **~6.8 GB** |
| `q4_0` / `iq4_nl` | 2592 MiB (2.5 GB) | 3.56x smaller | ~4.5 GB |

Those ratios come from the formats, not the model: `q8_0` stores 8 bits plus a 16-bit
scale per 32 elements, which is 8.5 effective bits against f16's 16, so 16 / 8.5 = 1.88.
The same ratios apply to any model, which is why the per-model table below scales the
known f16 cache.

### KV cache quantization is on by default

`BONSAI_KV_TYPE` defaults to `q8_0`. It costs a small amount of precision for a large
amount of memory, and at 64K context that trade is clearly worth taking.

| Value | Effect |
|---|---|
| `q8_0` | default. 1.88x smaller, near-lossless |
| `q5_0`, `q5_1` | ~2.9x smaller, small quality cost |
| `q4_0`, `q4_1` | 3.56x smaller, noticeable quality cost |
| `iq4_nl` | 3.56x smaller, usually better quality than `q4_0` |
| `f16`, `bf16` | no quantization; what upstream defaults to |
| `f32` | largest, highest precision |

```bash
./scripts/start-server.sh                              # q8_0, the default
BONSAI_KV_TYPE=f16 ./scripts/start-server.sh           # turn it off
BONSAI_KV_TYPE=iq4_nl ./scripts/start-server.sh        # push for memory
BONSAI_KV_TYPE_K=q4_0 BONSAI_KV_TYPE_V=q8_0 ./scripts/start-server.sh
./scripts/start-server.sh --kv-type q4_0               # same thing as the env var
```

The script validates the value against what the build actually accepts and fails with
the allowed list rather than letting llama-server reject it later.

> **On quality.** `q8_0` is widely treated as near-lossless for KV caches. `q4_0` is not:
> expect visible degradation on long contexts and reasoning-heavy prompts. Test before
> rolling it out to anyone else. This project has measured memory only, not quality.

### The 4x path, with quality recovered: `--kv-mean-center`

`q4_0` alone costs quality. The PrismML fork adds a way to get most of it back.

`--kv-mean-center` subtracts a precomputed per-(head, channel) bias from K before it is
quantized. Symmetric `q4_0` has no zero point, so a channel with a non-zero mean wastes
dynamic range encoding that constant offset; removing it first reduces quantization
error. Because the same bias is subtracted from every cached key, it shifts every
attention logit in a query's row by the same constant, which softmax is invariant to -
so the fork can argue the technique is exactly correct in infinite precision.

Build the bias file with one command:

```bash
./scripts/make-kv-bias.sh
```

It generates a calibration corpus from the model itself (no external data needed),
computes the bias, and prints the command to serve it. Then:

```bash
BONSAI_KV_TYPE_K=q4_0 BONSAI_KV_TYPE_V=q8_0 \
BONSAI_EXTRA_ARGS="--kv-mean-center models/kv-mean-center-<model>.gguf" ./scripts/start-server.sh
```

Measured on the 8B at 65536 tokens:

| Configuration | KV cache | vs f16 | Quality (logit KLD vs f16) |
|---|---|---|---|
| `f16` / `f16` | 9216 MiB (9.0 GB) | 1.00x | baseline |
| `q8_0` / `q8_0` (default) | 4896 MiB (4.8 GB) | 1.88x | near-lossless |
| **`q4_0` K + `q8_0` V + mean-center** | **3744 MiB (3.66 GB)** | **2.46x** | **0.00111** |
| `q4_0` / `q4_0` | 2592 MiB (2.5 GB) | 3.56x | noticeable loss |

The quality column is the fork's own measurement on a hybrid-attention model with a
`q4_0` K cache: 0.00111 with centering against 0.00144 uncentered, so centering recovers
about 23% of the divergence. This project verified the memory figures and that the whole
flow works; it did not re-measure quality.

**The basis must match.** The fork rotates the K cache before quantizing it, and the bias
lives in whatever basis the calibration used. `make-kv-bias.sh` always calibrates with
`-ctk q4_0` for exactly this reason. If you calibrate with the default `f16` cache and
then serve with `q4_0`, the loader refuses the file:

```
load_kv_mean_center: bias file ... was calibrated with the K-cache rotation inactive,
but it is active for this context - recalibrate with matching cache settings
```

That guard is deliberate: a mismatched bias is measurably worse than either feature
alone. The API surfaces only a generic "failed to load", so check `.state/server.log` for
the real reason.

**Limitations.** Scoped to `q4_0` K only. The calibration hook covers the standard
dense/GQA attention path, which includes the attention sub-cache of hybrid models like
Bonsai 2; MLA and other specialized variants are not covered. A bias is valid only for
the model and K cache type it was built for.

### Why not RotorQuant / PlanarQuant / IsoQuant?

They aim at the same problem - smaller KV cache with less quality loss - and the
underlying idea is sound. They are not adopted here because their llama.cpp implementation
is a competing rotation scheme in the same file PrismML already rotates in, and it would
mean rebasing thousands of lines of kernels across CPU, CUDA and Metal onto a five-month
newer tree. The full evidence, including what to watch for instead, is in
[ROTORQUANT-ASSESSMENT.md](ROTORQUANT-ASSESSMENT.md).

### Ask the machine directly

Rather than reading tables, ask:

```bash
./scripts/assess.sh --kv-matrix
```

It measures each model's cache geometry once, then computes the KV cost exactly for
every cache type, and reports what fits with how much headroom. See the
[README](../README.md#what-can-this-machine-actually-run).

The KV cost model behind it is exact rather than heuristic. The bit widths come from the
formats themselves - `f16` 16, `q8_0` 8 bits plus a 16-bit scale per 32 elements (8.5),
`q4_0` and `iq4_nl` 4.5 - and a single f16 measurement per model pins the rest. Verified
against hardware: the 8B measured 1152 MiB at 8192 cells and 9216 MiB at 65536, and the
model predicts q8_0 at 4896 and q4_0 at 2592, which are the measured values.

### Per model

Assuming the defaults: **65536 context and `q8_0` KV**.

| Model | Weights | KV (q8_0) | Min VRAM | Min RAM |
|---|---|---|---|---|
| 27B `PQ2_0` | 6.7 GB | ~3.8 GB | 11 GB | 15 GB |
| 27B `PTQ1_0` | 5.6 GB | ~3.8 GB | 10 GB | 14 GB |
| 27B `Q1_0` | 3.5 GB | ~3.8 GB | 8 GB | 12 GB |
| 8B `PQ2_0` | 2.0 GB | 4.8 GB | 7 GB | 11 GB |
| 8B `Q1_0` | 1.1 GB | 4.8 GB | 6 GB | 10 GB |
| 4B `PQ2_0` | 1.0 GB | ~4.2 GB | 6 GB | 9 GB |
| 4B `Q1_0` | 0.5 GB | ~4.2 GB | 5 GB | 8 GB |
| 1.7B `PQ2_0` | 0.4 GB | ~4.0 GB | 5 GB | 8 GB |
| 1.7B `Q1_0` | 0.2 GB | ~4.0 GB | 5 GB | 8 GB |

The 8B cache is measured exactly. The 27B cache is scaled from a measured end-to-end
total of 13.8 GB at `f16`, which implies ~7.1 GB of cache. The smaller models are scaled
estimates. Treat the last two columns as close guidance, not exact figures.

The headline consequence: **with `q8_0` the 27B fits in about 11 GB, so a 12 GB card can
run it at the full 64K context Hermes needs.** On `f16` it needs ~14 GB and does not.

### Splitting across VRAM and RAM

`assess.sh --sweep` measures the offload curve rather than estimating it. On the 8B at
32768 with `q8_0`, measured here:

| Layers on GPU | VRAM | RAM | tok/s | vs all-CPU |
|---|---|---|---|---|
| 0 | 0.0 GB | 4.4 GB | 16.2 | 1.0x |
| 12 | 3.1 GB | 1.4 GB | 21.9 | 1.4x |
| 24 | 3.7 GB | 0.7 GB | 34.3 | 2.1x |
| 36 | 4.4 GB | 0.0 GB | 75.5 | 4.7x |

Full offload is 4.7x the all-CPU rate, and the curve is steep at the top, so partial
offload buys less than it looks like it should. Note that the cache follows the layers:
`-ngl 0` puts it in RAM (llama.cpp logs a CPU KV buffer), and offloading any layer moves
it to VRAM. That is why the all-CPU row needs 4.4 GB of RAM for a 2.0 GB model.

### What actually moves throughput

Measured on the 8B at 16384 context. The ordering matters more than the exact figures:

| Change | Effect |
|---|---|
| Full GPU offload | up to **4.2x** (see the sweep below) |
| `f16` KV instead of `q8_0` | ~5% faster, 1.88x more cache |
| `q4_0` KV instead of `q8_0` | no measurable speed change |
| `--ubatch-size 256` | ~3% faster on this card |
| more or fewer threads | no measurable change under full offload |
| `--flash-attn off` | fails: a quantized V cache requires flash attention |

Run-to-run variance on this hardware is around 2-3%, so anything smaller than that is
noise. `./scripts/bonsai tune` measures the same set on your machine and will not call a
gap inside the noise a win.

The thread result is worth stating plainly because the usual advice is to tune it: with
every layer on the GPU, generation is bound by the GPU, and moving threads between 8 and
16 changed nothing measurable (87.1 against 86.9 tok/s).

### Speculative decoding

A draft predicts the next few tokens cheaply and the target verifies them, which can
multiply generation speed. Two mechanisms are supported here:

**The MTP head inside the model file.** A `*-mtp.gguf` carries the model's own
multi-token-prediction head, so no second file is needed:

```bash
BONSAI_SPEC_TYPE=draft-mtp ./scripts/bonsai start
```

**A separate drafter.** `BONSAI_DRAFT_MODEL` passes `--model-draft`. PrismML publishes
`Ternary-Bonsai-27B-dspark-Q4_1.gguf` (1.9 GB) for the 27B.

#### Measured here: use `n-max 1`

On an RX 9060 XT with the 27B lean MTP file at 65536 context and a `q8_0` cache, three
generations per configuration:

| Configuration | runs | median | draft acceptance |
|---|---|---|---|
| no speculative decoding | 36.6 / 37.0 / 37.0 | **37.0** | - |
| `draft-mtp`, `n-max 1` | 39.1 / 42.1 / 39.2 | **39.2** | 54% |
| `draft-mtp`, `n-max 2` | 32.0 / 35.0 / 36.8 | 35.0 | 48% |

`n-max 1` is worth about **6 to 13%**, and every run of it beat every run of the baseline.
**`n-max 2` is worse than not using it at all.** Acceptance falls from 54% to 48% while the
wider window costs more, because the stock PTQ1_0 mat-vec is inefficient at small batches.

That last point is why the advice differs between builds. A published guide for these
models recommends `n-max 2` on 12 GB cards and larger, and that is correct **for the build
it was measured on**, which carries a custom mat-vec kernel that cuts a 3-token batch from
2.28x to 1.55x a single-token pass. Without that kernel the wider window does not pay.
On a stock build, use `n-max 1`.

#### A HIP port of the NVIDIA mat-vec kernel was tried, and is slower

The CUDA PTQ1_0 mat-vec kernel described above is already in this tree, disabled for HIP
by a single gate (`ggml_cuda_q8_1_layout_for` in `common.cuh` and
`ptq1_0_pt_enabled()` in `mmvq-ptq1_0.cuh`). Enabling it for HIP is a three-file change,
and it was done and measured here rather than assumed.

**It is correct.** Batch-invariance, which is the kernel's whole point, holds: greedy
output with and without MTP was byte-identical on the ported build.

**It is much slower on this hardware.** 27B lean MTP file, 65536 context, `q8_0` cache,
RX 9060 XT:

| Build | no speculative decoding | `draft-mtp`, `n-max 1` |
|---|---|---|
| stock HIP | 36.4 tok/s | **41.3 tok/s** |
| the same build with the port | 24.8 tok/s | **7.3 tok/s** |

The control matters here: rebuilding the same tree with the change reverted returns 36.3
and 41.4, so the regression is the change and not the build configuration.

The likely reason is that the kernel's geometry is tuned for NVIDIA's 32-lane warps and its
planar activation layout suits NVIDIA's memory system. On AMD's 64-lane wavefronts it is a
32% loss at one column and a 5.6x loss at the two-column batches MTP needs. That is also
why the published +24% for MTP is NVIDIA-specific: their kernel helps there, while the same
path hurts on AMD.

So the port is not shipped. On AMD, MTP with the stock path is the win, and it is the +6 to
+13% measured above.

#### A smaller model from the same family does not work

Tested rather than assumed, because it looked promising: Bonsai 1.7B and Bonsai 8B are
both `qwen3` with a shared tokenizer, so the vocabulary is compatible and the server loads
the pair without complaint. Measured on the 8B at 8192, interleaved:

| Config | pass 1 | pass 2 |
|---|---|---|
| no draft | 90.9 | 90.9 |
| 1.7B draft, `n-max 3` | 87.2 | 91.0 |
| 1.7B draft, `n-max 8` | 86.8 | 88.8 |

No gain, and sometimes a loss. Too few of the 1.7B's predictions are accepted for
verification to pay for the drafting, which is why the published drafters are trained
against their specific target rather than being a smaller sibling. Compatible vocabulary
is necessary but nowhere near sufficient: the MTP head works because it was trained for
exactly this model.

### Vulkan versus ROCm, with and without MTP

Vulkan needs no ROCm at all, and the PTQ1_0 shaders are in the pinned build (upstream PR
#238 is an ancestor of it), so the no-ROCm path is real rather than partial. Measured on
an RX 9060 XT with the 27B lean MTP file at 65536 and a `q8_0` cache. Medians, two to
three generations per configuration:

| Backend | no MTP | `draft-mtp n-max 1` | `draft-mtp n-max 2` |
|---|---|---|---|
| ROCm (HIP) | 36.1 | 41.0 | 33.7 |
| **Vulkan** | 30.4 | 44.0 | **47.1** |

Three things follow.

**Without MTP, ROCm is faster** by about 16% (36.1 against 30.4).

**With MTP, Vulkan wins, and `n-max 2` is the best configuration measured here**: 47.1
against 41.0 for ROCm with `n-max 1`, a **15% gain**. This is the same effect the CUDA
kernel buys on NVIDIA: the small batches a draft needs are cheap on the Vulkan PTQ1_0
shader path and expensive on the HIP path, so on Vulkan the wider window pays and on ROCm
it does not. On ROCm `n-max 2` is clearly worse (33.7 against 41.0, three runs each).

**Vulkan is not batch-invariant.** ROCm's greedy output is byte-identical with and without
MTP; Vulkan's is not. Vulkan is deterministic (the same configuration twice gives the same
text), so this is a real difference in logits between batch sizes rather than noise, and it
showed up as a near tie flipping "most" to "much" in one paragraph. The text stays clean,
and for chat or agent use that is harmless, but if you need reproducible greedy output,
stay on ROCm.

So: fastest is Vulkan with `n-max 2`; most faithful is ROCm with `n-max 1`; and without MTP
ROCm is simply faster.

### Trading context for memory

Lowering the context shrinks the cache linearly, and stacks with the type:

```bash
BONSAI_CTX=16384 ./scripts/start-server.sh
```

At 16384 with `q8_0`, the 8B cache drops to about 1.2 GB and the 27B to about 0.95 GB.

Hermes needs at least 64000 tokens, so only lower this if you are calling the API
directly. `start-server.sh` warns when the value drops below that.

### CPU

Everything above applies to system RAM too, since the cache lives in memory either way,
plus a couple of GB of headroom for the process. KV quantization matters even more on
CPU, where memory bandwidth is usually the limit. CPU inference works but is slow, and
speed tracks bandwidth more than core count.

## Router mode and memory

The server runs in router mode with `--models-max 1`, so only one model is resident at
a time. Switching models unloads the current one first. That is what makes the 27B
models usable on a 16 GB card.

## Updating the pinned release

`PRISM_RELEASE` and `PRISM_COMMIT_FULL` in `scripts/lib/common.sh` are updated
together:

1. Pick a release from the PrismML releases page.
2. Set `PRISM_RELEASE` to its tag and `PRISM_COMMIT_FULL` to the full commit sha.
3. Update `PRISM_GFX_TARGETS` in `scripts/detect.sh` if the release changed its
   `GPU_TARGETS`.
4. Regenerate the UI patch if the upstream UI changed, then run
   `./tests/run.sh --with-patch --with-network`.
