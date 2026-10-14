# Kiln Dogfood Report

**Target:** Kiln local model server — real llama-server binary (`prism-b10772`, build 10772) on RTX 2070 Max-Q, CUDA backend, Ternary-Bonsai-8B model.
**Method:** Ran the actual server (not mocks), drove the CLI and OpenAI-compatible API against the live instance, probed edge cases. Per the `dogfood` skill.
**Scope:** Server startup, CLI surface, OpenAI-compatible API contract, error/edge handling.

## Executive Summary

| Severity | Count |
|---|---|
| Critical | 1 |
| High | 0 |
| Medium | 1 (upstream, not Kiln) |
| Low | 1 (flaky test) |

**The headline:** dogfooding against the real binary found a **production-blocking bug the entire 296-test suite missed** — the server would not start at all. This is the canonical argument for dogfooding over green-suite theater.

## Issues

### Issue 1 — CRITICAL: Server refuses to start on the pinned prebuilt

- **Category:** Functional
- **Symptom:** `start-server.sh` aborts immediately:
  ```
  error: invalid argument: --no-spec-type
  ```
- **Root cause:** `start-server.sh` emitted `--no-spec-type ngram-mod` unconditionally, but the pinned prebuilt (`prism-b10772`, build 10772) predates that flag. Its `--help` has `--spec-type` and `--spec-draft-*` but **no `--no-spec-type`**. Every start aborted.
- **Why the suite missed it:** the CMD-assembly test asserted the flag is *emitted*, never that the binary *accepts* it. Green suite, dead product.
- **Fix:** gate `--no-spec-type` on binary support via a shared `server_supports` helper (the same pattern `--moe-cache-mib` already used; extracted the inline grep into the helper). On a build without the flag, omitting it is correct (no additive ngram-mod default either).
- **Verified:** clean restart → healthy; `/v1/models` returns the model; a real chat completion succeeds. **First actual hardware number: 54.1 tok/s on RTX 2070** (vs fixture-derived estimates).
- **Status:** Fixed (`94b86f9`).

### Issue 2 — MEDIUM (upstream, not Kiln): malformed JSON returns 500

- **Category:** Functional (llama-server HTTP layer)
- **Symptom:** `POST /v1/chat/completions` with `{not json` returns HTTP 500, not 400.
- **Assessment:** this is llama-server's behavior. Kiln wraps the binary and does not own the HTTP layer. Correct client errors (400) for missing/wrong model and wrong method (404) are fine; only malformed-body is a 500. Noted for upstream, not a Kiln fix.

### Issue 3 — LOW: flaky stop-server test

- **Category:** Test infrastructure
- **Symptom:** "stop-server.sh must refuse to stop a foreign process" failed once, passed on re-run. The `lsof -ti` readiness poll has a race window.
- **Assessment:** unrelated to the startup fix; a test-timing flake, not a product bug. Not chased in this pass.

## What worked (no issues)

- **OpenAI-compatible API:** `/v1/models` lists the loaded model with correct id; `/v1/chat/completions` returns a valid completion with `usage` and `timings`. Router mode correctly requires a model (400 without one).
- **CLI against the live server:** `kiln status` detects the running pid, model, and GPU; `kiln speed` measures real tok/s.
- **Flag validation** (from the prior audit): unknown flags rejected with exit 2 and did-you-mean.

## Testing notes

- **Blocked:** the Web UI (llama-server's built-in page) could not be rendered — the browser backend is stuck on `lightpanda` and cannot load a real Chromium profile. In any case the Web UI is llama.cpp's code, not Kiln's, so dogfooding it would not test Kiln. The API contract (which Kiln *does* own) was tested directly via curl instead.
- **Cold-start timeout:** the first model load (2GB ternary, CUDA kernel compile) can exceed the default `KILN_START_TIMEOUT=90`. Not a bug, but a new user on first run may hit it; worth documenting or raising the default.
- **Models-dir gotcha:** running `get-models.sh --recommend` from the repo (without the installed prefix's env) saves to the repo's `models/`, not `~/models/kiln-server/`. Correct given the env, but a reproducibility sharp edge worth noting.
