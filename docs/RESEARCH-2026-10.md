# Research findings — pushing the throughput boundary (Oct 2026)

Sources: llama.cpp GH discussions #15021, #25198, #15396, #10879; Phoronix ROCm 7.1
vs RADV review; Unsloth Dynamic 3.0 docs; r/LocalLLaMA + r/ROCm benchmarks.
All findings cross-checked against our own measurements on this RX 9060 XT.

## 1. Backend: Vulkan wins on RDNA4 (confirmed twice)

**Community scoreboard (official RX 9060 XT, llama.cpp upstream):**
| model | HIP tg128 | Vulkan tg128 |
|---|---:|---:|
| Llama 7B Q4_0 (FA) | 65.4–67.6 | **71.1–74.0** |
| gpt-oss-20b MXFP4 | 92.8 | **105.8** |
| Qwen3.8-27B UD-IQ4_XS | 19.5 | **20.1** |
| Gemma 4 12B Q4_K_M | 37.6 | **39.0** |

**Our own same-file test (PTQ1_0-lean 27B @ 8192):** ROCm n-max 1 = **51.2**,
Vulkan n-max 2 = **54.9**. Vulkan +7%, and the optimal n-max is backend-specific
(Vulkan: 2, ROCm: 1) — so `--tune` must sweep the backend dimension, not assume.

Sanity check: our Bucoid 27B measured 18.8–19.4 against the scoreboard's 19.5/20.1
for the same Qwen3.8-27B IQ4_XS — our measurements are trustworthy.

## 2. The biggest untapped lever: `--spec-draft-p-min` — MEASURED, DEAD END HERE

Every MTP guide stops at n-max. The knob that matters is the draft *probability
floor* — it stops the draft head early when it's unsure. From GH discussion
#25198 (Gemma4-31B / Qwen3.6-27B, 5090):

| config | tok/s |
|---|---:|
| no speculation | 47 / 50 |
| n-max 1 | 78 / 77 |
| n-max 4 | 112 / 112 |
| **n-max 8 + p-min 0.8** | **163 / 178** |

Long-run log analysis: `n-max 16 + p-min 0.8` = **+15.9%** global TPS over
`n-max 4 + p-min 0`. Agentic/code workloads (repeated fragments) win most.

**Measured on THIS card (RX 9060 XT, Vulkan, Oct 2026, server path, 128 greedy
tokens) — the effect does NOT transfer:**

| config (PTQ1_0-lean @ 8192) | tok/s |
|---|---:|
| **n-max 2, no p-min** | **47.7** |
| n-max 3 | 39.0 |
| n-max 5 | 30.0 |
| n-max 4 + p-min 0.8 | 38.5 |
| n-max 8 + p-min 0.8 | 37.1 |
| n-max 16 + p-min 0.8 | 32.7 |

Deeper speculation *hurts* on this card and p-min does not rescue it. Likely
cause: the card is bandwidth-bound at ~288 GB/s, so the draft head's own
forward passes (same 5.9 GB weight traffic) dominate what the wider window
saves; on a 5090 the extra compute headroom absorbs them. **Conclusion: the
existing sweep (n-max 1 ROCm / n-max 2 Vulkan) is already optimal here. The
`--spec-draft-p-min` wiring is kept (correct infrastructure, default off) for
hardware where it helps, but the sweep must NOT add p-min variants.**

## 3. Models that clear 100 tok/s on THIS card — CORRECTED

**CORRECTION (Oct 13): the original version of this section called gpt-oss-20b
"the gem that clears 100". Wrong on two counts: gpt-oss is 2025-era (outdated
by ~a year), and web-search popularity ≠ current quality. Verified via the HF
API on 2026-10-13 — see docs/HF-LANDSCAPE.md for the corrected landscape.**

- Dense 27B caps ~55 tok/s on this card regardless of backend (bandwidth
  physics, validated twice: ROCm 51.2 / Vulkan 54.9 same-file).
- Anything ≤8B dense clears 100 (Bonsai-8B Q1_0 measured 123 here).
- **The real path to >100 is MoE architecture, not tuning**: MiniCPM-V-4.7
  35B-A3B (3B active) reads ~2 GB/token at Q3 → theoretical ~150 tok/s, needs
  measuring. gpt-oss-20b (105.8 on the upstream scoreboard) is the *proof of
  concept* that MoE clears 100 on this card, not a current recommendation.
- **Current gems (HF API, Oct 2026): Underdog-Saluki-27B (2-bit, beats
  full-size on tool calling), MiniCPM-V-4.7-35B-A3B (MoE), Qwen3.8-Flash-Next
  (MoE), Bonsai 2 (ternary). See HF-LANDSCAPE.md.**

## 3b. Speed vs quality are different axes (lesson from the correction)

- Speed axis: bytes-per-token → BW×η/W. MoE wins because *active* params are
  what get read, not total params.
- Quality axis: quant method × calibration. Saluki at 7.89 GB (2-bit) beats
  full-size Qwen3.8-27B (54 GB) on BFCL tool calling 88 vs 84.
- The discovery layer must rank on BOTH: a 5 % slower file with 20 points more
  tool-calling accuracy is the better recommendation for agentic workloads.

## 4. Quant landscape (2026)

- **Unsloth Dynamic 3.0 (UD-*)**: >10% top-1 accuracy at the same size vs every
  other provider; UD-Q4_K_S beats Q4_K_S while being 0.71 GiB *smaller*. Our Bucoid
  IQ4_XS is the old static style — `unsloth/Qwen3.8-27B-UD-IQ4_XS` is strictly
  better quality at identical size. Prefer UD-* in discovery ranking.
- **IQ4_NL for KV cache**: community reports it shines when paired with a Q6K+
  base quant (our KV_CACHE_TYPES already includes iq4_nl — worth adding to the sweep).
- MXFP4 (gpt-oss) is natively fast but Unsloth notes Q4_K > MXFP4 for quality
  when both are options.

## 5. Tuning knobs we don't currently sweep

- `--spec-draft-p-min` (see §2 — biggest gap)
- flash attention `-fa 1` (on by default for Gemma 4 sliding-window; check ours)
- n_batch / n_ubatch beyond 256/512/1024 (gpt-oss wanted 1536/4096)
- `HSA_OVERRIDE_GFX_VERSION=12.0.0` + gfx1201 + tensor-split tuning was reported
  to lift llama.cpp ROCm generation 19 → 29.7 tok/s on dual R9700 — worth a probe.

## 6. Where the model space is going (for discovery layer)

Current top-tier local families: **Qwen3.8-27B** (256K ctx, vision, MTP, "second
local model after Gemma 4 to reason through hard benchmarks"), **Gemma 4 12B/31B**
(sliding-window attention = long ctx at low KV cost, strong reasoning),
**gpt-oss-20b** (MoE speed king), **Muse/Glimmer 27B** (low KV/token, good agentic).
MTP acceptance is workload-dependent: 87–90% on code, 31–41% on prose — the
optimizer should not assume the 1.6× average holds everywhere.

## Action items for the optimizer
1. Add `--spec-draft-p-min` (0.8) + deeper n-max (8/12/16) to the `--tune` sweep. **P0**
2. Add backend as a swept dimension in `--tune` (validated: Vulkan wins here, but
   ROCm won n-max 1 — the winner must be measured, not assumed). **P0**
3. Add gpt-oss-20b MXFP4 + Unsloth UD-Qwen3.8-27B to the catalog as "fast path" picks. **P1**
4. Rank discovery candidates preferring UD-* quants and MTP/lean variants. **P1**
5. Add iq4_nl KV + wider ubatch range + -fa to the sweep. **P2**
