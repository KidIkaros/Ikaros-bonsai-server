---
name: kiln
description: Run and manage the Kiln local model server.
version: 0.1.0
author: Ikaaros (KidIkaros), Hermes Agent
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [local-llm, model-server, inference, llama-cpp]
    related_skills: []
---

# Kiln Skill

Kiln is a local model server: it runs PrismML Bonsai models on the user's own
hardware and exposes them as an OpenAI-compatible endpoint. Use this skill to
install it, start/stop the server, pick the fastest configuration, and point
Hermes at it. Kiln is dependency-free bash — no toolchain, no build step.

## When to Use

- The user asks to run a local model, serve a GGUF, or use a model "offline"/"on my machine".
- The user mentions Kiln, a local model server, or `kiln` commands.
- You need a local OpenAI-compatible endpoint for another tool to call.

Don't use for: cloud model APIs, or fine-tuning. Kiln serves pre-built GGUF
models; it does not train them.

## Prerequisites

- `kiln` on PATH (installed via Kiln's `install.sh`), or run from a Kiln
  checkout as `./scripts/kiln`.
- A CUDA/Vulkan/CPU backend is auto-detected; a GPU is optional.
- To talk to Hermes: the `hermes` CLI must be on PATH.

## How to Run

Drive Kiln through the `terminal` tool. The command is `kiln <subcommand>`
(or `./scripts/kiln <subcommand>` from a checkout).

## Quick Reference

| Task | Command |
|------|---------|
| One-command setup | `./setup.sh` (from a Kiln checkout) |
| Bring everything up (returning user) | `kiln up` — model + start + wire Hermes |
| Apply a named recipe | `kiln preset fastest|balanced|low-vram|safe` |
| Free VRAM when idle (load-on-demand) | `kiln set sleep-idle 300` (or `on`) |
| Is the server up? | `kiln status` |
| Start / stop / restart | `kiln start` / `kiln stop` / `kiln restart` |
| Download a recommended model | `./scripts/get-models.sh --recommend` |
| Find the fastest config on this machine | `kiln tune` |
| Persist the tune winner | `kiln apply` |
| See all measured speeds | `kiln fastest` (add `--json` for machines) |
| Quick tok/s check | `kiln speed` |
| Live dashboard | `kiln dash` (press `q` to quit) |
| Point Hermes at it | `./scripts/hermes-wire.sh --dry-run` then without `--dry-run` |
| Current settings | `kiln show` |
| Change a setting | `kiln set <key> <value>` (e.g. `kiln set ctx 32768`) |

## Procedure

The fastest path is one command: **`kiln up`** — it ensures a model exists
(recommending + downloading one for the hardware if none), starts the server,
and registers it with Hermes. Prefer it for onboarding and for "just get it
running." The granular steps below are for when the user wants control.

1. **Check state** — run `kiln status`. Completion: it reports the port, server
   state, and GPU. If `kiln` is not found, tell the user to install Kiln first.
2. **Bring it up** — run `kiln up`. Completion: `kiln status` shows `running`,
   and `hermes config get providers.local-127.0.0.1:8081.name` returns the
   provider (Kiln auto-registers; it does NOT force itself active, so the user
   still picks it in `hermes model`, exactly like any other provider).
3. **Tune for speed (optional)** — run `kiln tune`, then `kiln apply` to
   persist the winner. Completion: `kiln fastest --json` shows the tuned row
   at the top. Skip if the user just wants it working, not maximally fast.
4. **Wire Hermes manually (only if auto-wire was skipped, e.g. no `hermes` CLI
   at start time)** — run `./scripts/hermes-wire.sh --dry-run` first and show
   the user the commands, then run it for real. Completion: `hermes config get
   providers.local-127.0.0.1:8081.name` returns the provider name.

## Pitfalls

- **Never run `hermes-wire.sh` without `--dry-run` first** — it edits the
  user's live Hermes config. It backs the file up and prints the restore
  command, but show the dry run to the user before applying.
- `kiln dash` takes over the terminal in an interactive session; in a
  non-interactive/agent context it prints one static snapshot and exits, which
  is safe. Prefer `kiln status` / `kiln fastest --json` when scripting.
- The first model download is multi-GB; confirm the user wants it before
  running `get-models.sh`.
- A valueless flag like `hermes-wire.sh --model` (no id) refuses with an error
  — that is correct; supply `--model <id>`.

## Verification

After starting, prove it works end-to-end:

```bash
kiln status                      # running, with a port
kiln speed                       # a tok/s number, not an error
curl -s http://127.0.0.1:8081/v1/models   # lists the loaded model id
```

The `curl` hitting `/v1/models` confirms the OpenAI-compatible endpoint is
live — that is the contract any other tool (including Hermes) relies on.
