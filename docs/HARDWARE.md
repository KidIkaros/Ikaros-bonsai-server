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

The KV cache scales with **context length**, not model size. At the 65536 tokens Hermes
requires, the cache measured:

| Model | Weights | KV cache at 65536 | Total |
|---|---|---|---|
| 27B `PQ2_0` | 6.7 GB | ~7.1 GB | ~13.8 GB (measured end to end) |
| 8B `PQ2_0` | 2.0 GB | 9.7 GB | ~11.7 GB |
| 1.7B `Q1_0` | 0.24 GB | 7.5 GB | ~7.7 GB |

The 8B needs *more* cache than the 27B. The 27B is a hybrid-attention model that keeps
part of its state in a fixed-size recurrent form, so its cache grows more slowly.

Practical consequence: **budget 8-10 GB of VRAM for the cache at 64K context before you
count the weights at all.** Even the 1.7B needs about 8 GB to satisfy Hermes.

### Per model

| Model | Min VRAM | Min RAM | Notes |
|---|---|---|---|
| 27B `PQ2_0` | 14 GB | 18 GB | verified on a 16 GB card |
| 27B `PTQ1_0` | 13 GB | 16 GB | smaller weights, same cache |
| 27B `Q1_0` | 11 GB | 14 GB | |
| 8B `PQ2_0` | 12 GB | 14 GB | |
| 8B `Q1_0` | 11 GB | 13 GB | |
| 4B `PQ2_0` | 9 GB | 12 GB | cache estimated |
| 4B `Q1_0` | 9 GB | 11 GB | cache estimated |
| 1.7B `PQ2_0` | 8 GB | 10 GB | cache estimated |
| 1.7B `Q1_0` | 8 GB | 10 GB | |

The 27B row is anchored on a measured end-to-end total. The rest are the measured cache
plus the known weight size, so treat them as close estimates rather than exact figures.

### Trading context for memory

Lowering the context shrinks the cache roughly linearly, which is the only lever that
matters much:

```bash
BONSAI_CTX=16384 ./scripts/start-server.sh
```

At 16384 the cache drops to roughly a quarter of the 64K figure, so the 1.7B fits in
about 2.5 GB and the 27B in about 8.5 GB.

Hermes needs at least 64000 tokens, so only lower this if you are calling the API
directly. `start-server.sh` warns when the value drops below that.

### CPU

Everything above applies to system RAM too, since the cache lives in memory either way,
plus a couple of GB of headroom for the process. CPU inference works but is slow, and
speed tracks memory bandwidth more than core count. It is fine for testing and for the
small models.

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
