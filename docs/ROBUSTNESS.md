# Robustness — failure modes and the guards against them

Measured on an RX 9060 XT / Vulkan (radv) during Oct 2026 tuning work. Every
failure below was observed on this card, not theorized.

## 1. Wedged model load (the silent hang)

**Symptom:** VRAM climbs to the model size, then the process stalls during
compute-graph setup. The request never returns; the server appears started.

**Cause:** a previous load was killed mid-transfer (crash, `SIGKILL`, OOM) and
the GPU runtime never released its state. The *next* load then hangs. Clearing
the Mesa/Vulkan shader caches does **not** fix it — only `pkill -9 llama-server`
or a reboot recovers.

**Guards:**
- `start-server.sh` pre-flight: if VRAM is held (>2 GB) with no `llama-server`
  process running, warn and print the recovery command before starting.
- Background start waits for health with a bounded timeout, detects process
  death each second, and fails loudly with the log tail instead of exiting 0.

## 2. Spinner fills the disk

**Symptom:** a wedged loader writes its progress spinner to stdout without
bound. One stuck load was observed writing **1.7 GB** to a log file. On a
nearly-full disk this is unrecoverable.

**Guards:**
- `start-server.sh` refuses to start with <5 GB free, explaining why.
- Background mode truncates the log per start, so the failure tail is about
  the current attempt.

## 3. `/health` is not proof a model loads

**Symptom:** `/health` returns ok while the model load hangs, because in router
mode models load *per request*, not at startup. A health-only check reports
success and every subsequent request times out.

**Guard:** after `/health` passes, the startup check sends one real generation
request and distinguishes:
- `curl` rc 28 (timeout) → **wedged runtime**, fail with recovery steps
- other errors → warning only (that model may not fit; others may serve)
- success → healthy

## 4. Unbounded waits

**Guard:** every wait is bounded and every curl carries `--max-time`:
- `start-server.sh` startup: `BONSAI_START_TIMEOUT` (default 120s)
- `bench_tps` health poll: 120s loop + `--max-time 5` per curl
- `bench_tps` generation: `--max-time 300`

A non-responsive server can no longer stall the tuner or the startup path.

## 5. Process/port leakage between runs

**Symptom:** the test suite flaked once (135/1) while a manually started
`llama-server` still held port 8081. Three consecutive clean runs at 136/136
afterwards confirmed it was environment pollution, not a test bug — but it
shows how easily manual server starts contaminate later runs.

**Practice:** `pkill -9 -f '[l]lama-server'` (bracket form — a bare pattern
self-matches the killing shell's own command line) and verify the port is
clear before benching or testing.

## What is NOT guarded yet

- **Per-request hangs after startup.** A user requesting a wedged model gets a
  hung request with no server-side timeout. llama-server has no per-request
  load deadline; a proxy or client-side timeout is the realistic fix.
- **VRAM release after SIGKILL.** Still needs the pkill/reboot dance; the
  pre-flight warning is detection, not recovery.
