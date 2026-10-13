# Ikaros Bonsai server

A local model server for [Hermes](https://hermes.ai) and any other OpenAI-compatible
client, running PrismML's [Bonsai](https://huggingface.co/collections/prism-ml) models
on your own hardware.

Clone it, run one command, and you have a server on `http://localhost:8081` that
Hermes can talk to. No cloud account, no API key, no GPU required.

```bash
git clone https://github.com/KidIkaros/Ikaros-bonsai-server.git
cd Ikaros-bonsai-server
./setup.sh
```

That is the whole install. `setup.sh` works out what hardware you have, downloads the
matching prebuilt binary, and pulls a model that fits. Then:

```bash
./scripts/start-server.sh     # leave this running
./scripts/hermes-wire.sh      # in another terminal, point Hermes at it
```

### Or install it as a command

If you would rather not keep a clone around, `install.sh` puts a `bonsai` command on
your `PATH` (no root needed). After that, `bonsai` works from any directory, in any
shell:

```bash
./install.sh                  # installs to ~/.local
bonsai detect                 # what hardware was found, which backend
bonsai start                  # first run downloads the binary + a model
bonsai status
```

`./install.sh --prefix /opt/bonsai` installs elsewhere, `--status` shows what is
installed, `--uninstall` removes it. Re-run `install.sh` from a newer checkout to
update. Release tarballs (`.tar.gz` + checksum) are built automatically on every
`v*` tag; extract one and run its `install.sh` to install without cloning.

Tab completion is installed alongside the command when your shell's completion
directory is writable (bash, zsh and fish). To place it by hand:

```bash
bonsai completions bash > ~/.local/share/bash-completion/completions/bonsai
bonsai completions zsh  > ~/.zfunc/_bonsai     # then: autoload -U compinit && compinit
bonsai completions fish > ~/.config/fish/completions/bonsai.fish
```


---

## What is a Bonsai model?

Bonsai models are *quantised* language models. Ordinary models store every weight as a
16-bit number; Bonsai stores most of them in about 1 to 2 bits. The practical effect is
that a 27-billion-parameter model shrinks from roughly 54 GB to about 6-7 GB, which is
small enough to run on a single consumer GPU or even on a CPU.

The trade is that Bonsai models are narrower than the biggest hosted models. They are
good at reasoning, coding and tool calling, and they run entirely on your machine, so
nothing you type leaves the computer.

These models need a **patched llama.cpp** to run. This project handles that for you by
downloading PrismML's official prebuilt binaries.

## What you get

| | |
|---|---|
| OpenAI-compatible API | `http://localhost:8081/v1` |
| Built-in chat UI | `http://localhost:8081` |
| Router mode | switch models live, no restart |
| Context window | 65536 tokens by default, which is what Hermes needs |
| Backends | ROCm/HIP, CUDA, Vulkan, CPU - auto-detected |
| Model catalog | official PrismML models plus curated community fine-tunes |

## Requirements

- Linux x86_64 or arm64 (Windows is not supported yet)
- `curl` or `wget`, and `git`
- `python3` for the JSON in `status`, `speed` and `assess` (no third-party
  packages; any Python 3 works). Everything else is plain shell.
- About 3 GB of disk for the binary plus whatever your chosen model needs
- **Nothing else for the default path.** No compiler, no Node, no pip install.

Rough hardware guidance:

| Your machine | Backend | Sensible model |
|---|---|---|
| AMD GPU, ROCm 7.2+, 12 GB+ | HIP | 27B `PQ2_0` (~11 GB) |
| NVIDIA GPU, 12 GB+ | CUDA | 27B `PQ2_0` (~11 GB) |
| GPU with 8 GB | either | 8B `PQ2_0` (~7 GB) |
| Any Vulkan 1.2+ GPU | Vulkan | 8B `PQ2_0`, or `Q2_0_g64` for the 27B |
| No GPU at all | CPU | 8B `Q1_0`, or 1.7B for a quick test |

`setup.sh` picks for you and tells you what it chose.

> **Read this before picking a model.** At the 65536-token context Hermes requires, the
> **KV cache is usually the biggest consumer of VRAM, not the weights** - 9 GB on the
> 8B before any quantization. This project therefore quantizes it by default
> (`BONSAI_KV_TYPE=q8_0`), which cuts the cache by 1.88x at negligible quality cost and
> is what makes the 27B fit a 12 GB card. See
> [docs/HARDWARE.md](docs/HARDWARE.md#vram-and-ram) for the measurements and the other
> options.

## Pointing Hermes at it

```bash
./scripts/hermes-wire.sh --dry-run    # print exactly what would change
./scripts/hermes-wire.sh              # apply it
```

The script backs up your Hermes config first and prints the restore command. It reads
the model id from the running server, so start the server first.

Then pick the **Bonsai** provider in Hermes.

<details>
<summary>Doing it by hand instead</summary>

```bash
hermes config set --force "providers.local-127\.0\.0\.1:8081.api"           "http://127.0.0.1:8081"
hermes config set --force "providers.local-127\.0\.0\.1:8081.name"          "Bonsai"
hermes config set --force "providers.local-127\.0\.0\.1:8081.default_model" "<model id>"
hermes config set --force "model.provider" "local-127.0.0.1:8081"
hermes config set --force "model.default"  "<model id>"
```

The backslashes are required: Hermes splits config keys on dots, and this provider id
contains dots.

</details>

> **One thing to know:** the server runs in *router* mode, so every request must name a
> model. Hermes does this for you. If you call the API directly, pass `"model": "<id>"`
> or you will get `model name is missing from the request`. List the ids with
> `curl -s localhost:8081/v1/models`.

## Getting models

```bash
./scripts/get-models.sh                      # interactive picker
./scripts/get-models.sh --list               # everything, with fit info
./scripts/get-models.sh --list abliterated   # filter by tag
./scripts/get-models.sh --recommend          # best fit for this machine
./scripts/get-models.sh --get 7              # download catalog entry 7
```

Any Hugging Face repo works, not just the catalog:

```bash
./scripts/get-models.sh --repo prism-ml/Bonsai-8B-gguf --list
./scripts/get-models.sh --repo <owner>/<name> --file '*PQ2_0*'
```

Downloads are resumable and verified against the size Hugging Face reports. Set
`HF_TOKEN` for private or gated repos.

The catalog covers the official PrismML family and a curated set of community
fine-tunes (abliterated, uncensored, heretic, CRACK and others). See
[docs/MODELS.md](docs/MODELS.md) for the full list and the format compatibility
matrix.

> **Format warning.** Only formats this llama.cpp build understands will load. Files
> for a different runtime - MLX, GSQ-RCO, NInfer, AWQ - are detected and refused with
> a clear message rather than failing later.

## What can this machine actually run?

```bash
./scripts/assess.sh                # assess installed models at 65536 / q8_0
./scripts/assess.sh --kv-matrix    # every KV cache type side by side
./scripts/assess.sh --measure      # measure KV cost for installed models
./scripts/assess.sh --measure --speed   # also benchmark tokens per second
./scripts/assess.sh --sweep             # split across VRAM and RAM, measure each
```

It reports weights, KV cache, total and headroom per model, then tells you the largest
one that fits:

```
  model                                         weights       KV    total     spare  verdict
  prism-ml_Bonsai-1.7B-gguf__Bonsai-1.7B-Q1_0      0.2G     3.7G     3.9G     10.1G  fits  194.9 tok/s
  prism-ml_Ternary-Bonsai-8B-gguf__Ternary-Bon     2.0G     4.8G     6.8G      7.2G  fits
```

Two things make this different from a generic fit calculator:

- **It knows PrismML's quant formats and measures your models**, rather than estimating
  from a generic bytes-per-parameter rule.
- **It treats the KV cache as a first-class cost.** `--kv-matrix` shows what changing
  the cache type does to the verdict, which is usually the difference between fitting
  and not fitting.

Speed is **measured, never estimated**. Run `--measure --speed` once per model; until
then the column is simply absent rather than filled with a guess. Measured numbers move
a few percent between runs, so treat them as a guide rather than a constant.

`--measure` is a one-off per model: it loads each one briefly at a 512-token context to
read its cache geometry, which is exact and cheap.

### Splitting a model across VRAM and system RAM

A model does not have to fit in VRAM. llama.cpp can keep some layers on the GPU and run
the rest from system RAM, so a model larger than your card still runs, just slower. The
question is where the knee is, and that is worth measuring rather than guessing:

```bash
./scripts/assess.sh --sweep
```

```
    on GPU      VRAM       RAM      tok/s vs all-CPU
         0      0.0G      4.4G       16.2       1.0x
        12      3.1G      1.4G       21.9       1.4x
        24      3.7G      0.7G       34.3       2.1x
        36      4.4G      0.0G       75.5       4.7x

Best: all 36 layers on the GPU, 75.5 tok/s.
```

It picks the splits itself from the model's layer count and your free budget, measures a
short generation at each, and prints the command to serve the winner. The VRAM and RAM
columns account for the fact that the KV cache follows the layers: with `-ngl 0` the
cache lives in RAM, and offloading any layer moves it to VRAM.

Options: `--sweep-tokens N` to change the sample size, `--sweep-levels 0,18,36` to pick
the splits yourself, `--context` and `--kv-type` as above.

## Everyday use

```bash
./scripts/start-server.sh              # foreground, opens the Web UI
./scripts/start-server.sh --background # detached, logs to .state/server.log
./scripts/stop-server.sh               # stop it
./scripts/stop-server.sh --status      # is it running?

BONSAI_PORT=9000 ./scripts/start-server.sh   # different port
BONSAI_CTX=32768 ./scripts/start-server.sh   # smaller context, less VRAM
BONSAI_KV_TYPE=iq4_nl ./scripts/start-server.sh   # smaller KV cache, more models fit
BONSAI_KV_TYPE=f16 ./scripts/start-server.sh      # no KV quantization
```

To push the cache to a quarter of its f16 size without giving up quality, build a
mean-centering bias file and pair it with a `q4_0` K cache:

```bash
./scripts/make-kv-bias.sh                          # one command, no external data
BONSAI_KV_TYPE_K=q4_0 BONSAI_KV_TYPE_V=q8_0 \
BONSAI_EXTRA_ARGS="--kv-mean-center models/kv-mean-center-<model>.gguf" \
./scripts/start-server.sh
```

See [docs/HARDWARE.md](docs/HARDWARE.md#the-4x-path-with-quality-recovered---kv-mean-center)
for the measured numbers.

## Running it

Everything goes through one command. You do not need to know systemd:

```bash
./scripts/bonsai start      # start it
./scripts/bonsai status     # is it up, on which port, what is loaded
./scripts/bonsai stop
./scripts/bonsai logs -f
./scripts/bonsai speed      # quick tokens/sec check
./scripts/bonsai fastest    # every measured configuration on this backend, fastest first
./scripts/bonsai bench      # measure a model on this machine (writes its row)
./scripts/bonsai identity   # is the MTP draft lossless on this backend?
./scripts/bonsai tune       # find the fastest settings on this machine
./scripts/bonsai assess     # what fits
./scripts/bonsai models     # what is installed
./scripts/bonsai help
```

### Settings, without reinstalling

`./scripts/bonsai set` writes a plain settings file, `.state/service.env`:

```bash
./scripts/bonsai set ctx 32768
./scripts/bonsai set kv iq4_nl
./scripts/bonsai set ngl 24
./scripts/bonsai restart      # apply
```

The file is readable and editable by hand, and it is the single source of settings for
both the launcher and the service. Changing a value never means reinstalling anything. A
value exported in your shell still wins, so a one-off
`BONSAI_CTX=8192 ./scripts/start-server.sh` works too.

### As a service (optional)

```bash
./scripts/install-service.sh
```

This writes a systemd **user** unit and stops there. It does **not** enable it and does
**not** start it — a model server holds VRAM and CPU the whole time it runs, so starting
it is always your decision. Once installed, `./scripts/bonsai start` uses the service
automatically; without it, `bonsai` starts the server in the background instead.

```bash
systemctl --user enable ikaros-bonsai    # only if you want it at login
```

### The speed-first defaults

Three levers carry the measured speed, in order of size: **full GPU offload**
(up to 4.2x), the **MTP speculative head** (+23-33% with a grafted file on
Turing/Ampere, +15% on Vulkan, +6% on ROCm), then the KV cache type (a few
percent). The first two are applied for you:

- `start-server.sh` keeps `-ngl 99`, the full offload.
- When the models directory holds a `*-mtp.gguf`, `draft-mtp` is switched on
  automatically and the draft window is picked per backend (Vulkan 2, ROCm and
  CUDA 1) - the measured winner on each. Override with `BONSAI_SPEC_TYPE=none`.
- llama.cpp's own default spec type, `ngram-mod`, is removed first with
  `--no-spec-type ngram-mod`: `--spec-type` is additive upstream, and on the
  PrismML ternary models `ngram-mod` silently no-ops (accepted, no log output,
  decode unchanged) while still sharing the verify batch. Set
  `BONSAI_SPEC_STACK=upstream` to keep it. See
  [docs/SPEED-BEYOND-MTP-2026-10.md](docs/SPEED-BEYOND-MTP-2026-10.md) for the
  measurements and the other model-file-independent speed levers.

`fastest` reads only rows this machine measured, on this backend and release.
`fastest --json` emits the same rows as JSON for a script or agent to consume
(`rows[].tok_s`, `draft_acceptance`, `offload_layers`; unrecorded fields are
`null`, never a guessed `0`):

```
  backend cuda   release prism-b10772-e8fd209   card GeForce RTX 2070

    tok/s  model                                      offload  measured at
    46.1  Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean            36  65536 ctx, q4_0 KV
    42.6  Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean            36  65536 ctx, q4_0 KV
```

A number with no row behind it is never shown; run `bench` (or `--measure
--speed`, or `--sweep`) to create the rows first.

### Speed is one axis, not the whole answer

`fastest` and `--tune` rank on tok/s but report two things that decide whether
a number is *advice*:

- **draft acceptance** — the share of drafted tokens the target model accepted.
  Below **0.10** the verify passes cost more than the drafts save, so a weak
  row is marked as such and a weak-draft variant is not allowed to take the
  top slot in `--tune`. A spec type that prints no draft line at all (which is
  what `ngram-*` does on the PrismML ternary models, issue #203) is reported
  as **no drafts**, not as zero acceptance.
- **losslessness** — `bonsai identity` runs the same greedy prompt with the
  draft on and off and compares the text byte for byte. On CUDA
  `GGML_CUDA_BATCH_INVARIANT=1` makes them identical; on Vulkan (which has no
  equivalent) a near-tie can flip a token, which the check reports plainly.

`--tune` also starts one server per variant instead of one per repetition
(three reps inside a single load, median taken): the cache-type flags are
start-time, so the old per-rep restarts bought the same measurement three
times as slowly.

## Getting the most tokens per second

Measured on the 8B at 16384 context, and the same shape applies elsewhere:

| Change | Effect | Why |
|---|---|---|
| **Full GPU offload** (`-ngl` = all layers) | **up to 4.2x** | the single biggest lever; see the sweep below |
| `f16` KV instead of `q8_0` | ~5% faster | no dequantization in attention, but 1.88x more cache |
| `q4_0` KV instead of `q8_0` | no measurable change | 3.56x less memory for free, but costs quality |
| `--ubatch-size 256` instead of 512 | ~3% faster on this card | smaller physical batches |
| More or fewer threads | **no measurable change** | under full offload the CPU is not the bottleneck |
| `--flash-attn off` | **fails** | a quantized V cache requires flash attention |

The ordering matters more than the exact numbers: offload first, then decide the KV type
by how much memory you have, and ignore thread tuning.

`--tune` measures these on **your** machine rather than trusting the table above, and
refuses to call a difference smaller than run-to-run noise a win:

```bash
./scripts/bonsai tune
```

```
  ranked                                        tok/s vs default
  f16 KV, ubatch 512                             93.5      1.05x
  q8_0 KV, ubatch 512 (default)                  89.2      1.00x
  q8_0 KV, ubatch 256                            89.1      1.00x
  q8_0 KV, ubatch 1024                           83.8      0.94x
  q4_0 KV, ubatch 512                            83.0      0.93x

Fastest: f16 KV, ubatch 512 at 93.5 tok/s.
  Serve it with:
    BONSAI_KV_TYPE=f16 ./scripts/start-server.sh
```

That is the trade in one line: `f16` KV buys about 5% and costs 1.88x the cache. If the
cache does not fit, take `q8_0` and lose almost nothing, or `q4_0` and lose only quality.

### Speculative decoding

This beats everything above. If your model file is a `*-mtp.gguf` it already carries the
MTP head, so no second file is needed:

```bash
BONSAI_SPEC_TYPE=draft-mtp ./scripts/bonsai start
```

Measured here on the 27B MTP file at 65536 with a `q8_0` cache, three generations each:

| Configuration | median tok/s | draft acceptance |
|---|---|---|
| no speculative decoding | 37.0 | - |
| `draft-mtp`, `n-max 1` | **39.2** | 54% |
| `draft-mtp`, `n-max 2` | 35.0 | 48% |

So about **+6%** on ROCm, and `n-max 2` is *worse than not using it* there — acceptance
drops while the wider window costs more.

**The backend changes the answer.** Vulkan needs no ROCm and its PTQ1_0 shaders are in the
pinned build, and on Vulkan the wider window does pay:

| Backend | no MTP | `n-max 1` | `n-max 2` |
|---|---|---|---|
| ROCm | 36.1 | 41.0 | 33.7 |
| Vulkan | 30.4 | 44.0 | **47.1** |

Vulkan with `n-max 2` is the fastest configuration measured here at **47.1 tok/s, 15%
above** ROCm with `n-max 1`. Vulkan is slower without MTP, and it is not batch-invariant
(a near tie can flip a token), so stay on ROCm if you need reproducible greedy output. See
[docs/HARDWARE.md](docs/HARDWARE.md#vulkan-versus-rocm-with-and-without-mtp).

```bash
BACKEND=vulkan ./scripts/setup.sh          # no ROCm needed
BONSAI_SPEC_DRAFT_N_MAX=2 ./scripts/bonsai start
```

There is also `BONSAI_DRAFT_MODEL` for a separate `*-dspark-*` drafter. Using a smaller
Bonsai as a drafter for a bigger one was tested and does not work: the vocabulary is
compatible, but too few predictions are accepted. See
[docs/HARDWARE.md](docs/HARDWARE.md#speculative-decoding).

## The speed-log UI patch (optional, source build)

The prebuilt binaries come from unmodified upstream source, so they cannot contain
this project's UI changes. If you want the smoothed tokens-per-second display and the
per-response speed log, build from source:

```bash
./scripts/build-from-source.sh --check   # verify the patch applies (fast)
./scripts/build-from-source.sh           # clone, patch, build
```

This needs `cmake`, a C++ toolchain and Node.js, and takes a while. The result lands in
`bin/<backend>-patched/` and automatically takes precedence over the prebuilt binary.
Remove that directory to go back to the prebuilt.

See [docs/SOURCE-BUILD.md](docs/SOURCE-BUILD.md) for details.

## Documentation

| | |
|---|---|
| [docs/MODELS.md](docs/MODELS.md) | the model catalog, sizes and format compatibility |
| [docs/HARDWARE.md](docs/HARDWARE.md) | backends, VRAM/RAM guidance, ROCm notes |
| [docs/HERMES.md](docs/HERMES.md) | provider wiring, context requirements, model ids |
| [docs/SOURCE-BUILD.md](docs/SOURCE-BUILD.md) | the patched source build |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | when something goes wrong |
| [docs/ROTORQUANT-ASSESSMENT.md](docs/ROTORQUANT-ASSESSMENT.md) | why RotorQuant/PlanarQuant were not adopted |

## How this relates to other projects

- [PrismML-Eng/llama.cpp](https://github.com/PrismML-Eng/llama.cpp) - the fork that
  adds the low-bit formats and publishes the binaries this project downloads.
- [PrismML-Eng/Bonsai-demo](https://github.com/PrismML-Eng/Bonsai-demo) - PrismML's own
  official demo, which also sets up models and binaries. If you want a batteries-included
  demo with Open WebUI and vision, use that. This project is narrower: a headless
  OpenAI-compatible server aimed at pointing an existing client at a local model.
- [sudoingX/local-ai-on-your-gaming-gpu](https://github.com/sudoingX/local-ai-on-your-gaming-gpu)
  - the same idea taken deeper on a single model. It hand-tunes serve scripts per VRAM
  tier, carries a **CUDA PTQ1_0 mat-vec kernel** that measured 1.5x decode on an RTX 3060,
  uses the model's **MTP head for speculative decoding** (~+24%), supports Windows, and
  grows a per-card measurement table by PR. Its kernel is CUDA-only, so on AMD this
  project's ROCm or Vulkan path is what you want; if you are on an RTX card, look there
  first.

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `BONSAI_PORT` | `8081` | listening port |
| `BONSAI_HOST` | `127.0.0.1` | listening address; `0.0.0.0` to reach the server from other machines on your network |
| `BONSAI_CTX` | `65536` | context size |
| `BONSAI_NGL` | `99` | GPU layers |
| `BONSAI_KV_TYPE` | `q8_0` | KV cache type: `q8_0`, `q5_0`, `q4_0`, `iq4_nl`, `f16` to disable |
| `BONSAI_KV_TYPE_K` / `_V` | follow `BONSAI_KV_TYPE` | set the two halves independently; `_V` alone quantizes only the value cache (measured near-lossless, unlike quantizing K) |
| `BONSAI_MODELS_DIR` | `./models` | where models are stored |
| `BONSAI_THREADS` | all logical cores | CPU threads; measured as noise under full GPU offload, the largest lever on CPU-only or partial-offload |
| `BONSAI_EXTRA_ARGS` | unset | extra `llama-server` flags, e.g. `--ubatch-size 256` |
| `BONSAI_SPEC_DRAFT_P_MIN` | `0.0` | draft probability floor (disabled); `0.8` lets deeper `n-max` pay off on some hardware |
| `BONSAI_START_TIMEOUT` | `120` | seconds to wait for the server to become healthy; raise it for a slow first load |
| `BONSAI_DRAFT_MODEL` | unset | a `*-dspark-*` drafter for speculative decoding |
| `BONSAI_SPEC_TYPE` | unset | `draft-mtp` to use the MTP head inside a `*-mtp.gguf` (auto-enabled when one is installed); `none` to disable |
| `BONSAI_SPEC_STACK` | `bonsai` | `upstream` keeps llama.cpp's default `ngram-mod` alongside the chosen type; `bonsai` removes it first (it no-ops on the ternary models) |
| `BONSAI_SPEC_DRAFT_N_MAX` | `1` | tokens to draft; 2 measured slower on a stock build |
| `BONSAI_KV_BIAS_OUT` | `models/kv-mean-center-<model>.gguf` | where `make-kv-bias.sh` writes the bias file |
| `BONSAI_CALIB_TOKENS` | `400` | tokens the model generates per seed prompt when building a KV bias |
| `BONSAI_MOE_CACHE_MIB` | unset | GPU cache for CPU-resident MoE experts, `+1.5-1.85x` decode (needs a source build; the pinned prebuilt lacks the flag) |
| `BACKEND` | auto | force `cpu`, `vulkan`, `cuda` or `rocm` |
| `HF_TOKEN` | unset | for private or gated Hugging Face repos |
| `HSA_OVERRIDE_GFX_VERSION` | unset | only if your gfx target is not covered |

## License

MIT for this repository. The binaries are downloaded from PrismML's releases and stay
under their MIT license. Model weights have their own licenses - check the model card
before redistributing them. See [NOTICE](NOTICE) for full attribution.
