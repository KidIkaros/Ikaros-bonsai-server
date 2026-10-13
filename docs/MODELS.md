# Models

Everything here is driven by [`scripts/models.catalog`](../scripts/models.catalog),
a plain pipe-delimited file:

```
repo | file | size_gb | min_vram_gb | min_ram_gb | tags
```

Sizes are the on-disk size. `min_vram_gb` and `min_ram_gb` are guidance for
comfortable inference at the default 65536 context, not hard limits. A `0` in
`min_vram_gb` marks an auxiliary file (a vision projector) that is loaded
alongside a model rather than run on its own.

**These numbers assume the defaults: 65536 context and `q8_0` KV cache.** They are
dominated by the KV cache, not the weights - at 65536 tokens the cache alone measured
9.0 GB on the 8B before quantization, and 4.8 GB after. Setting `BONSAI_KV_TYPE=f16`
adds roughly 4 GB to the 8B row and about 3 GB to the 27B row. See
[HARDWARE.md](HARDWARE.md#vram-and-ram).

`--list` marks each row `*` when it fits the detected machine and `-` when it does not.

## Format compatibility

The pinned PrismML build supports these formats:

| Backend | `Q1_0` | `PQ2_0` | `PTQ1_0` | `Q2_0` |
|---|:---:|:---:|:---:|:---:|
| CPU | yes | yes | yes | yes |
| CUDA | yes | yes | yes | yes |
| ROCm / HIP | yes | yes | yes | yes |
| Vulkan | yes | partial | partial | yes |
| Metal (macOS) | yes | yes | yes | yes |

Plus the standard `Q4_K`, `Q5_K`, `Q6_K` and `Q8_0` formats that upstream llama.cpp
handles.

- **`Q1_0`** is the earlier 1-bit Bonsai format, not a Bonsai 2 packing.
- **`PQ2_0`** is PrismML's group-128 `Q2_0`. Slightly smaller, slightly faster prompt
  processing, preferred on CUDA/HIP/Metal/CPU.
- **`Q2_0_g64`** (older repos name it `Q2_0`) is the official group-64 format. It runs
  on every backend **and** on stock llama.cpp, so it is the safe choice when unsure.
- **Vulkan `PQ2_0`/`PTQ1_0`** are partial: kernel selection depends on the device and
  driver. Prefer `Q2_0_g64` or `Q1_0` on Vulkan.

### Refused formats

These are detected and skipped with a message rather than failing at load time:

| Marker in filename | Why it is refused |
|---|---|
| `-mlx`, `mlx-2bit` | Apple MLX format, not a GGUF llama.cpp can read |
| `gsq-rco` | GSQ-RCO, different runtime, no kernels in this fork |
| `ninfer` | NInfer, different runtime |
| `awq` | AWQ, different runtime |

If you ask for a repo whose only files are in one of these formats, `get-models.sh`
says so and downloads nothing.

## Official models

The `prism-ml` family. These are the models upstream tests against.

| Model | File | Size | Min VRAM | Min RAM |
|---|---|---|---|---|
| Bonsai 2 27B | `Ternary-Bonsai-2-27B-PQ2_0.gguf` | 7.21 GB | 11 GB | 15 GB |
| Bonsai 2 27B | `Ternary-Bonsai-2-27B-PTQ1_0.gguf` | 5.95 GB | 10 GB | 14 GB |
| Bonsai 2 27B (vision) | `Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf` | 0.63 GB | - | - |
| Ternary-Bonsai 27B | `Ternary-Bonsai-27B-Q2_g64.gguf` | 7.59 GB | 11 GB | 15 GB |
| Ternary-Bonsai 8B | `Ternary-Bonsai-8B-PQ2_0.gguf` | 2.18 GB | 7 GB | 11 GB |
| Ternary-Bonsai 4B | `Ternary-Bonsai-4B-PQ2_0.gguf` | 1.08 GB | 6 GB | 9 GB |
| Ternary-Bonsai 1.7B | `Ternary-Bonsai-1.7B-PQ2_0.gguf` | 0.46 GB | 5 GB | 8 GB |
| Bonsai 27B | `Bonsai-27B-Q1_0.gguf` | 3.80 GB | 8 GB | 12 GB |
| Bonsai 8B | `Bonsai-8B-Q1_0.gguf` | 1.16 GB | 6 GB | 10 GB |
| Bonsai 4B | `Bonsai-4B-Q1_0.gguf` | 0.57 GB | 5 GB | 8 GB |
| Bonsai 1.7B | `Bonsai-1.7B-Q1_0.gguf` | 0.25 GB | 5 GB | 8 GB |

The 1.7B entries are tagged `smoke-test`: small enough to download and verify a setup
in seconds.

## Community fine-tunes

Also in the catalog: Bonsai 2 27B variants published by other people. Abliterated
(refusals removed), uncensored, heretic, CRACK, MTP and long-context builds.

**These are not validated** by this project or by PrismML. They are listed because they
exist and are popular. A repo can still ship a mislabelled or broken GGUF. Treat them
as you would any third-party model download.

To browse them:

```bash
./scripts/get-models.sh --list abliterated
./scripts/get-models.sh --list uncensored
./scripts/get-models.sh --list mtp
```

## Arbitrary Hugging Face repos

```bash
./scripts/get-models.sh --repo <owner>/<name> --list
./scripts/get-models.sh --repo <owner>/<name> --file '*PQ2_0*'
./scripts/get-models.sh --repo <owner>/<name> --file 'exact-file.gguf'
```

Unsupported formats are skipped with a warning. Set `HF_TOKEN` for gated repos.

## Adding to the catalog

Append a line to `scripts/models.catalog`. Keep it six fields, keep the size accurate,
and use only formats from the compatibility table above. `./tests/run.sh` fails the
build if a row has the wrong field count, duplicates another `repo|file`, or names an
unsupported format.

## Where models live

`./models/` by default, as `<owner>_<repo>__<file>.gguf`. That naming keeps files from
different repos from colliding and is what the router reports as the model id (minus
the `.gguf`). Override with `BONSAI_MODELS_DIR`.
