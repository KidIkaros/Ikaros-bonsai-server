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

### A quality lever for q4_0 K

The PrismML fork adds `--kv-mean-center`, which subtracts a precomputed per-(head,
channel) bias from K before it is quantized. Symmetric `q4_0` has no zero point, so a
channel with a non-zero mean wastes dynamic range encoding that constant offset; removing
it first reduces quantization error. The fork ships a softmax-invariance argument for why
this is exactly correct in infinite precision.

It is scoped to `q4_0` K and needs a calibration file from `tools/kv-mean-center`:

```bash
BONSAI_KV_TYPE_K=q4_0 BONSAI_KV_TYPE_V=q8_0 \
BONSAI_EXTRA_ARGS="--kv-mean-center /path/to/bias.gguf" ./scripts/start-server.sh
```

See [MODELS.md](MODELS.md) for whether a bias file exists for your model.

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
