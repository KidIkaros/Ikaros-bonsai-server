# Wiring Hermes

Hermes talks to this server over its OpenAI-compatible API. The provider lives in the
Hermes config file, which is a live user config - so the wiring script backs it up
first and can be run in dry-run mode.

## The easy way

Start the server, then:

```bash
./scripts/hermes-wire.sh --dry-run    # print the commands, change nothing
./scripts/hermes-wire.sh              # apply them
```

The script:

1. reads the model list from the running server at `/v1/models`
2. lets you pick one, or uses the only one available
3. backs up the config to `<config>.bak-<timestamp>`
4. writes the provider through the `hermes` CLI
5. reads the provider back to confirm it worked

It prints the exact restore command at the end. It is safe to re-run.

Useful flags:

| Flag | Effect |
|---|---|
| `--dry-run` | print what would change, touch nothing |
| `--model <id>` | skip the prompt, use this model id |
| `--name "..."` | display name for the provider (default `Bonsai (local)`) |
| `--make-default` | also set `model.provider` and `model.default` |

## Doing it by hand

```bash
hermes config set --force "providers.local-127\.0\.0\.1:8081.api"           "http://127.0.0.1:8081"
hermes config set --force "providers.local-127\.0\.0\.1:8081.name"          "Bonsai"
hermes config set --force "providers.local-127\.0\.0\.1:8081.default_model" "<model id>"

hermes config set --force "model.provider" "local-127.0.0.1:8081"
hermes config set --force "model.default"  "<model id>"
```

### The backslashes are required

Hermes parses config keys on `.`, so `providers.local-127.0.0.1:8081.api` is read as
the nested path `providers` -> `local-127` -> `0` -> `0` -> `1:8081` -> `api`, and
Hermes refuses it with:

```
Refusing to create nested key 'local-127' in 'providers.local-127.0.0.1:8099.api'
```

Escaping each dot in the provider id - `local-127\.0\.0\.1:8081` - keeps it as a single
literal key. That is what the wiring script does.

## Model ids

The id is the model's filename without `.gguf`, including the repo prefix:

```
prism-ml_Ternary-Bonsai-2-27B-gguf__Ternary-Bonsai-2-27B-PQ2_0
prism-ml_Bonsai-8B-gguf__Bonsai-8B-Q1_0
```

List what is currently available:

```bash
curl -s http://localhost:8081/v1/models | python3 -m json.tool
```

### Every request must name a model

The server runs in router mode, so it does not have a single "current" model to fall
back on. A request without `model` gets:

```json
{"error":{"code":400,"message":"model name is missing from the request"}}
```

Hermes sends the model id from its provider config, so this only bites you when calling
the API directly:

```bash
curl -s http://localhost:8081/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"prism-ml_Bonsai-8B-gguf__Bonsai-8B-Q1_0",
       "messages":[{"role":"user","content":"hello"}],
       "max_tokens":32}'
```

## Context window

Hermes requires at least 64000 tokens of context. The server defaults to 65536, which
is why `start-server.sh` warns if you set `IKAROS_CTX` below that. Bonsai 2 supports up
to 262144, but every extra token of context costs VRAM.

## Model aliases

A convenient pattern is to register the provider once and let the model id change as
you swap models:

```bash
hermes config set --force "providers.local-127\.0\.0\.1:8081.default_model" "prism-ml_Bonsai-8B-gguf__Bonsai-8B-Q1_0"
```

Because the server is in router mode, downloading another model and pointing Hermes at
its id needs no server restart.

## Tool calling

The server starts with `--jinja`, so `/v1/chat/completions` accepts the standard OpenAI
`tools` array and returns structured `tool_calls`. Bonsai 2 27B is trained for agentic
tool use.

## Undoing the change

The wiring script prints the backup path. Restore with:

```bash
cp ~/.hermes/config.yaml.bak-<timestamp> ~/.hermes/config.yaml
```

Or remove just the provider:

```bash
hermes config unset "providers.local-127\.0\.0\.1:8081"
```
