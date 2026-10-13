# HF landscape — verified via API, 2026-10-13

**Method note:** every fact below comes from `huggingface.co/api/models`
(metadata: creation date, likes, downloads, file sizes, architecture) or the
repo README — NOT from web search. An earlier research pass anchored on search
popularity and wrongly recommended gpt-oss (2025-era). Search engines surface
what's *popular*, not what's *current*. This doc is the API-first method the
discovery layer must use.

## The current gems (all created within the last 30 days)

### 1. Underdog Saluki 27B 1.0 — quality gem
- `ConwayResearch/Underdog-Saluki-27B-1.0` — created **2026-10-08**, 404 likes,
  269,829 downloads (5 days old!)
- File: `Underdog-Saluki-27B-1.0-IQ2-mix.gguf` — **7.36 GiB** (README says 7.89 GB
  decimal), arch `qwen35`, 262144 ctx, **stock llama.cpp — no custom kernels**
- Base: `ISTA-DASLab/Qwen3.8-27B-GSQ-RCO-GGUF`, apache-2.0
- MTP variant: `Kujira/Underdog-Saluki-27B-1.0-MTP-GGUF` →
  `Underdog-Saluki-27B-1.0-IQ2-mix-MTP.gguf` — **7.78 GiB**, MTP head grafted
  (repo ships `graft_mtp.py`), 19,975 downloads
- Abliterated MTP variant also exists (Kujira)
- Vision add-on: `mmproj-Underdog-Saluki-27B-1.0-F16.gguf` (928 MB) or Q8_0 (629 MB)

**Benchmarks (their harness, BFCL v4 120 tasks, thinking off, temp 0):**

| Model | Size | BFCL passed | Parallel calls |
|---|---|---|---|
| **Saluki 27B 1.0** | 7.89 GB | **88** | **42** |
| Qwen3.8-27B full | 54 GB | 84 | 35 |
| Bonsai 2 (PTQ1_0) | 5.95 GB | 70 | — |

96% average retention across 9 benchmarks; ~82–85% of competition-math score.
Known limits: weak on letter-level instruction puzzles; some parallel-call
formatting slips; reasons at length with thinking on.

**Run flags:** `--jinja` (required for tool calls + thinking), `-ngl 99`,
`-fa on`, `-c 32768`. Thinking per-request via
`chat_template_kwargs {"enable_thinking": false}` for fast tool calls (temp 0).

**Speed on this card (estimated):** 7.36 GiB weights → ~28 tok/s single-stream,
~44 with MTP n-max 2. *Slower than our PTQ1_0-lean (54.9), much better quality.*
Speed/quality tradeoff, not a speed pick.

### 2. MiniCPM-V-4.7-35B-A3B — the MoE speed path
- `openbmb/MiniCPM-V-4.7-35B-A3B` — created **2026-10-07**, 439 likes,
  trendingScore 397; GGUF repo `openbmb/MiniCPM-V-4.7-35B-A3B-gguf`
- Arch `qwen35moe` — **35B total / ~3B active**, multimodal, 262144 ctx
- Files: F16 (64.6 GiB), Q4_0/Q4_1/Q4_K_M/Q4_K_S (~19–20 GB — too big for us),
  Q5/Q6/Q8, **`mix_q3gud_im.gguf` (~15 GB — the one that fits 16 GB)**,
  `mmproj-model-f16.gguf`, `mmproj-model-f16-4x.gguf`
- Also `openbmb/MiniCPM-V-4.7-1B` (275 likes) and MiniCPM5-2B family
  (`openbmb/MiniCPM5-2B` — note: user's memory records a MiniCPM5-1B eval:
  Q8_0 ≈ F16 but repetition collapse + weak instruction following)

**Why it matters:** decode reads only *active* experts (~1.5–2 GB/token at Q3),
so the BW×η formula uses active params. Theoretical ceiling ~150 tok/s on this
card — **the architecture-level answer to ">100 tok/s" that dense 27B cannot
reach by tuning.** Must be measured: expert-gather overhead in llama.cpp
Vulkan may not realize the promise.

### 3. Qwen3.8-Flash-Next — MoE, popular
- `Qwen/Qwen3.8-Flash-Next` — MoE; `orcarouter/Qwen3.8-Flash-Next-Uncensored-GGUF`
  has 653,893 downloads (Aug 26). Vision + function-calling + reasoning.

### 4. DFlash2 — a second spec-decoding path (not MTP)
- `z-lab/Qwen3.8-27B-DFlash2` — draft-model approach (arxiv 2602.06036), paired
  with ternary Bonsai 2 (`Cyronius/Qwen3.8-27B-DFlash2-Bonsai2-ternary`,
  `naklitechie/...`). Alternative to MTP heads — worth evaluating if MTP
  acceptance disappoints on prose.

### 5. Bonsai 2 — still current (user-confirmed gem)
- `sudoingx/Ternary-Bonsai-2-27B-PTQ1_0-MTP-GGUF` — 67 likes, 44,263 downloads
  (the file we run at 54.9 tok/s), plus `CaryPalmer/Ternary-Bonsai-2-27B-262k-GGUF`
  (262k ctx, 26 likes) and many abliterated/uncensored variants.
- Saluki's own benchmark table puts Bonsai 2 at 70/120 BFCL vs Saluki's 88 —
  Saluki is the quality upgrade at ~1.3× the weight bytes.

## Landscape principles for the discovery layer

1. **Query the API, not search engines.** `?search=<name>&sort=lastModified`
   and `?sort=trendingScore` give dates + real download counts. Search results
   are popularity-weighted and years stale.
2. **`createdAt` is the freshness signal.** A 5-day-old model with 270k
   downloads outranks a 2-year-old one with 10M.
3. **`gguf.architecture` from the API** tells you `qwen35` vs `qwen35moe` —
   MoE changes the speed formula entirely (active params, not total).
4. **`gguf.total` / `totalFileSize`** give exact bytes for the ceiling estimate.
5. **READMEs carry the benchmark tables** — fetch `raw/main/README.md` for the
   models that survive filtering; that's where quality rankings live.
6. **Pair MTP files with base quants** (Qwen needs separate modules; Saluki's
   MTP variant is a distinct repo).
