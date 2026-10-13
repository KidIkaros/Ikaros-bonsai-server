# Unsloth study — quant tiers, MTP, and what the discovery layer must know

Sources: unsloth.ai/docs/basics/dynamic-3.0-ggufs, /docs/models/qwen3.8,
/docs/models/mtp; HF API for unsloth/Qwen3.8-27B-GGUF (6.6M downloads, 5,045
likes, last modified 2026-08-20). All quant names/sizes verified against the
live repo file listing.

## 1. Unsloth Dynamic 3.0 (UD-*) — what it is

Post-training quantization only (no QAT/QAD, no training on the calibration
imatrix — overfitting analysis published). Calibration dataset refined for
**agentic coding, chat, and multilingual**. Result: **>10% top-1 accuracy at
identical file size vs every other provider**. The imatrix file is public
(`imatrix_unsloth.gguf`) so anyone can reproduce or derive from it.

**Discovery-layer implication:** when two candidates have the same byte size,
a `UD-*` file is the better pick — quality is free at fixed bandwidth cost.
This belongs in the ranking heuristic (§6).

## 2. The quant ladder (Qwen3.8-27B, verified file list)

| File | Size class | Fits RX 9060 XT 16 GB? |
|---|---|---|
| `UD-Q8_K_XL/L` | ~31 GB | ✗ |
| `UD-Q6_K_XL/L/M` | 23–26 GB | ✗ |
| `UD-Q4_K_XL` | ~17.9 GB | ✗ full offload (RAM offload only) |
| `UD-Q5_K_M/S/XL` | ~20 GB | ✗ |
| `UD-Q4_K_M/S` | ~16 GB | borderline — 8K ctx max |
| **`UD-IQ4_XS`** | **~13.3 GB** | **✅ fits, 8192 ctx + q8_0 KV** |
| `UD-Q3_K_XL` | 12–14 GB | ✅ fits, smaller ctx |
| **`UD-Q2_K_XL`** | **9.83 GB** | **✅ +8% top-1 over next best; room for long ctx** |
| `UD-IQ3_S/XXS` | 9–11 GB | ✅ |
| `UD-IQ2_S/XXS` | ~8.4 GB | ⚠️ quality cliff starts |
| `UD-IQ1_S` | 6.2 GB | ⚠️ 72% top-1, breaks agentic |

Non-UD fallbacks in the same repo: `Q4_0`, `Q4_1`, `Q8_0`.

**Hardware table from Unsloth (RAM+VRAM, 27B):** 1-bit 7–8 GB · 2-bit 9–11 ·
3-bit 12–14 · 4-bit 16–19 · 6-bit 23–26 · 8-bit 31 · BF16 56. MTP adds 1–2 GB.

## 3. The quality cliff — critical for speed-maximizing configs

Divergence-300 @32 (greedy 32-token agreement with BF16) drops from ~25% at
UD-Q2_K_XL to **under 8–10% below it**. In plain terms:

- Tool calling / agentic mode **breaks** below UD-Q2_K_XL
- Sub-2-bit: excessive looping (mitigate with `presence_penalty=1.5`), empty
  responses unless thinking mode is on
- 1-bit retains ~72–77% top-1 (general knowledge) but is unusable for
  multi-step inference

**Design rule for the optimizer:** never recommend a quant below the cliff for
agentic/tool-calling workloads — a faster file that fails the task is not a
win. The floor is `UD-Q2_K_XL` for general use, `UD-IQ4_XS`/`UD-Q3_K_XL` when
context headroom matters.

## 4. MTP specifics from Unsloth

- Speedup: **1.4×–2.2×** generation; dense 27B/31B benefit most; smaller gains
  on low-bandwidth devices (us — we measured 1.56×, consistent)
- **"Do not assume 2 is optimal — try any value from 1 through 6 and use
  whichever is fastest for your system."** Our data confirms: Vulkan wanted 2,
  ROCm wanted 1. Hardware-dependent, as they say.
- MTP memory cost: ~2 GB extra headroom
- Reference: Qwen3.6-27B MTP = 160 tok/s, Qwen3.6-35B-A3B = 240 tok/s on RTX 6000
- Qwen needs a **separate MTP module** (`MTP/mtp-Qwen3.8-27B-Q4_0.gguf`) — it
  is NOT embedded in the main GGUFs. Gemma 4 embeds it. **The discovery layer
  must pair a Qwen MTP file with its base quant, or it silently gets no speedup.**
- MTP module was removed from quants ≤ UD-Q2_K_XL size — below that tier you
  must attach the standalone Q4_0 MTP module.

## 5. Sampling profiles (Qwen3.8-27B is a hybrid-thinking model)

| Param | Thinking | Instruct |
|---|---|---|
| temperature | 1.0 | 0.7 |
| top_p | 0.95 | 0.80 |
| top_k | 20 | 20 |
| presence_penalty | 0.0 | 1.5 |

`reasoning_effort` ∈ {xhigh (default), medium, low, none} via
`--chat-template-kwargs '{"reasoning_effort":"medium"}'` — a *speed* lever the
tuner could offer for latency-sensitive use. Context: 262144 native, 1M via YaRN.

## 6. What the discovery layer must encode

1. **Prefer UD-\* at equal byte size** (quality free at fixed bandwidth)
2. **Enforce the quant floor** per workload: agentic/tools → ≥ UD-Q2_K_XL;
   chat → ≥ UD-IQ3_S; speed-first chat → UD-IQ2_S acceptable
3. **Pair Qwen MTP module with base quant**; flag Gemma 4 as self-contained
4. **Arch comes from the HF API `gguf` field** (`architecture: qwen35`,
   `context_length`) — parse it rather than guessing from filenames
5. **Popularity as a quality signal**: downloads + likes (6.6M/5k here) rank
   models the community has actually validated
6. **Size → ceiling** via the BW×η formula, then *subtract the quant-cliff
   candidates* before ranking on speed

## 7. Verified facts to write into the catalog

- `unsloth/Qwen3.8-27B-GGUF` — UD-* ladder, apache-2.0, vision (mmproj-F16/BF16
  included), MTP module at `MTP/mtp-Qwen3.8-27B-Q4_0.gguf`, 256K ctx
- Best picks for this card: `UD-IQ4_XS` (~13.3 GB, max quality that fits) or
  `UD-Q2_K_XL` (9.83 GB, long-context headroom, still above the cliff)
- Benchmarks: beats Qwen3.6-27B and Muse Glimmer-30B on SWE-bench Pro
  (61.7 vs 53.5/51.2), Terminal Bench 2.1 (73.0 vs 63.4/51.7), LiveCodeBench
  v6 (90.3) — strongest local model for agentic coding as of Oct 2026
