# Troubleshooting

Start with the two self-checking commands:

```bash
./scripts/detect.sh            # what it thinks the hardware is
./scripts/stop-server.sh --status
```

`detect.sh` writes everything to `.state/detect.env`, which every other script reads.
If detection is wrong, everything downstream is wrong.

---

## Setup and downloads

### `No prebuilt asset resolved for backend 'cuda'`

Your combination of OS, architecture and backend has no published binary. arm64 has no
CUDA or ROCm assets. Force a different backend:

```bash
BACKEND=cpu ./setup.sh
BACKEND=vulkan ./setup.sh
```

### The download stops partway

Downloads are resumable. Run the same command again and it continues:

```bash
./scripts/fetch-binary.sh
```

A truncated archive is detected and deleted rather than left to fail later with an
opaque `tar` error.

### `Downloaded file is not a valid gzip archive`

Almost always a partial download or a captive-portal HTML page. The file is removed
automatically; re-run to retry.

### `Could not read <repo>. Private or gated?`

Set a token. Public repos download anonymously:

```bash
HF_TOKEN=hf_xxx ./scripts/get-models.sh --repo <owner>/<name> --list
```

### `No .gguf files in <repo>`

The repo exists but holds no GGUF files - it is probably MLX, safetensors, or a
LoRA-only repo.

### A model is skipped with `format not supported by the pinned fork`

The file is for a different runtime (MLX, GSQ-RCO, NInfer, AWQ). See
[MODELS.md](MODELS.md#refused-formats). Nothing is downloaded, because it could not be
loaded afterwards.

---

## Starting the server

### `Port 8081 is already in use`

Something is already listening. Find out what, then either stop it or use another port:

```bash
./scripts/stop-server.sh --status
BONSAI_PORT=9000 ./scripts/start-server.sh
```

### `No .gguf files in <models dir>`

Download one first: `./scripts/get-models.sh --recommend`.

### The server starts but the model never loads

Check the log, then the format:

```bash
tail -50 .state/server.log
```

The usual cause is a file the pinned build cannot read. The error names the file and
often the format it expected instead.

### `model name is missing from the request`

Not a fault. Router mode has no default model, so every request must name one. Hermes
does this; direct API calls must include `"model": "<id>"`. See
[HERMES.md](HERMES.md#every-request-must-name-a-model).

### `llama-server did not run cleanly` on a HIP build

The prebuilt targets ROCm 7.2. If your ROCm is a different major version, build for your
own installation:

```bash
./scripts/build-from-source.sh
```

### Model fails to load on AMD, or garbage output

Your gfx target may not be in the prebuilt's `GPU_TARGETS`. `detect.sh` says so:

```
[WARN] gfx target gfxNNNN is not in the pinned prebuilt's GPU_TARGETS.
```

Build from source, or try an override with the closest supported target:

```bash
HSA_OVERRIDE_GFX_VERSION=11.0.0 ./scripts/start-server.sh
```

### Runs but very slow on CPU

Two common causes:

1. **No AVX512.** `detect.sh` reports it. The 1-bit CPU kernel falls back to a scalar
   path that is far slower. Not fixable in software.
2. **Too large a model for the machine.** Try 8B `Q1_0` or the 1.7B.

Also lower the context if you are calling the API directly rather than through Hermes:

```bash
BONSAI_CTX=16384 ./scripts/start-server.sh
```

---

## Hermes

### `Refusing to create nested key 'local-127'`

The provider id contains dots and Hermes splits keys on dots. Escape them:

```
providers.local-127\.0\.0\.1:8081.api
```

`scripts/hermes-wire.sh` does this for you.

### Hermes cannot reach the provider

Confirm the server answers, then that the provider is registered:

```bash
curl -s http://localhost:8081/health
hermes config get "providers.local-127\.0\.0\.1:8081" --json
```

If the server is running but Hermes cannot connect, check the model id in the provider
matches something in `curl -s localhost:8081/v1/models` exactly.

### Context window error from Hermes

Hermes needs at least 64000 tokens. The default is 65536. If you lowered `BONSAI_CTX`,
raise it back.

### Restore the config

```bash
cp ~/.hermes/config.yaml.bak-<timestamp> ~/.hermes/config.yaml
```

---

## The service

### It is not running after `install-service.sh`

Correct behaviour. The installer deliberately does not enable or start it. A model
server holds VRAM for as long as it runs, so starting it is your decision:

```bash
systemctl --user start ikaros-bonsai
systemctl --user status ikaros-bonsai
journalctl --user -u ikaros-bonsai -n 50
```

### It will not start at boot

```bash
systemctl --user enable ikaros-bonsai
```

Also check lingering is on if you want user services to run without an active login:

```bash
loginctl enable-linger "$USER"
```

---

## The source build

### `Patch does not apply`

The upstream UI changed. Regenerate the patch - see
[SOURCE-BUILD.md](SOURCE-BUILD.md#regenerating-the-patch).

### `Node.js not found`

The UI is built from source on this path, so Node is required. Install Node 20+, or use
the prebuilt path (`./scripts/fetch-binary.sh`) and accept that the speed log will be
absent.

### `Speed-log UI patch confirmed present` is missing

The build ran but the marker was not found. The server still works. Verify the patch
applied:

```bash
grep -r "bonsai_speed_log" .build/llama.cpp/build-<backend>/tools/ui/dist
```

---

## Reporting a problem

Include:

```bash
./scripts/detect.sh --json
./scripts/stop-server.sh --status
tail -50 .state/server.log
```

and the exact command you ran.
