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
- About 3 GB of disk for the binary plus whatever your chosen model needs
- **Nothing else for the default path.** No compiler, no Python, no Node.

Rough hardware guidance:

| Your machine | Backend | Sensible model |
|---|---|---|
| AMD GPU, ROCm 7.2+, 16 GB | HIP | 27B `PQ2_0` (~14 GB VRAM) |
| NVIDIA GPU, 16 GB | CUDA | 27B `PQ2_0` (~14 GB VRAM) |
| GPU with 12 GB | either | 8B `PQ2_0` (~12 GB VRAM) |
| Any Vulkan 1.2+ GPU | Vulkan | 8B `PQ2_0`, or `Q2_0_g64` for the 27B |
| No GPU at all | CPU | 8B `Q1_0`, or 1.7B for a quick test |

`setup.sh` picks for you and tells you what it chose.

> **Read this before picking a model.** At the 65536-token context Hermes requires,
> the **KV cache costs roughly 7-10 GB on its own**, whatever the model size. It is
> usually the biggest single consumer of VRAM, not the weights. A 27B that fits in
> 14 GB and a 1.7B that needs 8 GB are both real numbers. Dropping the context
> shrinks the cache proportionally - see
> [docs/HARDWARE.md](docs/HARDWARE.md#vram-and-ram) for the measurements.

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

## Everyday use

```bash
./scripts/start-server.sh              # foreground, opens the Web UI
./scripts/start-server.sh --background # detached, logs to .state/server.log
./scripts/stop-server.sh               # stop it
./scripts/stop-server.sh --status      # is it running?

BONSAI_PORT=9000 ./scripts/start-server.sh   # different port
BONSAI_CTX=32768 ./scripts/start-server.sh   # smaller context, less VRAM
```

## Running it as a service (optional)

```bash
./scripts/install-service.sh
```

This writes a systemd **user** unit and stops there. It does **not** enable it and does
**not** start it. A model server holds VRAM and CPU the whole time it runs, so starting
it is always your decision:

```bash
systemctl --user start ikaros-bonsai     # when you want it
systemctl --user stop  ikaros-bonsai
systemctl --user enable ikaros-bonsai    # only if you want it at login
```

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

## How this relates to other projects

- [PrismML-Eng/llama.cpp](https://github.com/PrismML-Eng/llama.cpp) - the fork that
  adds the low-bit formats and publishes the binaries this project downloads.
- [PrismML-Eng/Bonsai-demo](https://github.com/PrismML-Eng/Bonsai-demo) - PrismML's own
  official demo, which also sets up models and binaries. If you want a batteries-included
  demo with Open WebUI and vision, use that. This project is narrower: a headless
  OpenAI-compatible server aimed at pointing an existing client at a local model.

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `BONSAI_PORT` | `8081` | listening port |
| `BONSAI_CTX` | `65536` | context size |
| `BONSAI_NGL` | `99` | GPU layers |
| `BONSAI_MODELS_DIR` | `./models` | where models are stored |
| `BACKEND` | auto | force `cpu`, `vulkan`, `cuda` or `rocm` |
| `HF_TOKEN` | unset | for private or gated Hugging Face repos |
| `HSA_OVERRIDE_GFX_VERSION` | unset | only if your gfx target is not covered |

## License

MIT for this repository. The binaries are downloaded from PrismML's releases and stay
under their MIT license. Model weights have their own licenses - check the model card
before redistributing them. See [NOTICE](NOTICE) for full attribution.
