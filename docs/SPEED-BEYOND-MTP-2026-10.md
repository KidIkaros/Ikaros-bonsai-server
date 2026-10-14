# Speed beyond MTP — research, Oct 2026

Research into decode-speed levers that do **not** depend on a model file carrying an
MTP head. Motivation: `draft-mtp` only works on `*-mtp.gguf` files, which most models
do not ship, so a tool that auto-configures llama.cpp cannot lean on it.

All claims cite a primary source (llama.cpp upstream `master` / `PrismML-Eng/llama.cpp`
`prism` branch, fetched 2026-10-13). Reddit numbers are marked secondary and
lower-confidence.

---

## 1. The model-file-independent path: n-gram / lookup spec-decode

Five spec types need **no draft model, no head, no GPU backend** — they draft from the
token history already in context ("a copy machine"). Pure CPU-side logic; verified in
source: `common/speculative.cpp` gates the four `draft-*` types on a loaded draft
context, the five n-gram types are enabled unconditionally.

| spec-type | needs `-md`? | notes |
|---|---|---|
| `ngram-simple` | no | nearest n-gram match in history, draft following m-gram; `--spec-ngram-simple-size-n/-size-m/-min-hits` (12/48/1) |
| `ngram-map-k` | no | hash-map of context n-grams, per-n-gram acceptance tracking |
| `ngram-map-k4v` | no | up to 4 candidate continuations, drafts the dominant one — **experimental** |
| `ngram-mod` | no | LCG hash pool, next token only, ~16 MB constant memory, **pool shared across all server slots** |
| `ngram-cache` | no | statistical n-gram cache, optional external stats files |

Sources: [docs/speculative.md](https://github.com/ggml-org/llama.cpp/blob/master/docs/speculative.md) ·
[common/speculative.cpp](https://github.com/ggml-org/llama.cpp/blob/master/common/speculative.cpp)

### Measured numbers

- **PR #18471** (self-speculation, merged 2026-01-28): gpt-oss-120b **181 → 446 tok/s
  (2.46×)**, acceptance 0.768; Qwen3-235B heavily offloaded **11.8 → 21.0 tok/s**,
  acceptance 0.863. Author's caveat, quoted: *"This speedup factor occurs only in
  favorable cases with large repeated sections."* https://github.com/ggml-org/llama.cpp/pull/18471
- **PR #27210** (2× R9700, Qwen3.8-27B Q8_0, baseline 30 t/s): `ngram-mod` = 30.03 /
  30.10 / 29.98 on reasoning/prose/code (**exactly neutral on dense work**) but
  **292.88 t/s on "recall" (9.8×)**. `draft-mtp` fixed-3 = 51.7 / 55.9 / 69.3.
  https://github.com/ggml-org/llama.cpp/pull/27210
- **PR #29548** (RTX 3090): a verbatim-repeat prompt after a bug fix: 159/159 drafts
  accepted, decode **21.7 → 83.8 tok/s (3.9×)**. Before the fix the drafter ran 198
  times and produced zero tokens.
  https://github.com/ggml-org/llama.cpp/pull/29548
- **5060 Ti 16GB, Qwen3.6-35B-A3B** (secondary, r/LocalLLaMA): baseline vs ngram-mod —
  16K depth 96 → **149 tok/s (1.55×)**, 32K 88 → 137, 65K 76 → 108.
- **CRLF kills it** (PR #19164 comment): Devstral-2-123B, same file + "repeat
  verbatim" — LF = 29.79 tok/s @ 0.83 acceptance; CRLF = 2.32 tok/s @ 0.115.
  https://github.com/ggml-org/llama.cpp/pull/19164

### ⚠️ The negative results — read these before enabling anything

1. **On this project's own models, n-gram spec silently no-ops.** PrismML issue #203:
   on Ternary-Bonsai-2 (hybrid GDN/linear-attention target) `--spec-type ngram-*` is
   accepted, produces zero log lines, `timings.draft_n == null`, and decode is
   identical to `none` (31.7 tok/s). A generic 4B drafter (`draft-simple -md`) gave a
   **net slowdown** (5.7–12.2 vs 31.7 baseline).
   https://github.com/PrismML-Eng/llama.cpp/issues/203
2. **All spec types lose on small-active-parameter MoE (A3B-class) on consumer
   Ampere.** RTX 3090 / Qwen3.6-35B-A3B Q4_K_XL 19-config matrix (HackMD
   [ODXuOQNzSiyUITz7g9mtBw](https://hackmd.io/ODXuOQNzSiyUITz7g9mtBw)): baseline
   **135.7 tok/s**; every n-gram variant 119–134 (some @ 100% acceptance); `-md
   Qwen3.5-0.8B` **55–66 tok/s (−53…−60%)**; best tuned config 85.6 (−39%). Root cause
   attributed to MoESD (arXiv 2505.19645) / Utility-Driven SD (arXiv 2506.20675):
   expert-saturation threshold far above any realistic draft K — each drafted token
   drags fresh expert slices through memory. **100% acceptance cannot rescue it.**
   Counter-evidence in the same dataset: srogmann's numbers on Qwen3.5-122B-A10B
   (10B active) get +15–45% — the sign flips with active params, not model size.
3. **Upstream changed the default.** PR #28391 makes `ngram-mod` the **default**
   spec type: `--spec-type` is now *additive* to the default, and `--no-spec-type
   ngram-mod` removes it. A config that passes `--spec-type draft-mtp` gets
   `[ngram-mod, draft-mtp]` unless it also passes `--no-spec-type ngram-mod`.
   https://github.com/ggml-org/llama.cpp/pull/28391
4. **ngram-mod gotchas:** an early low-acceptance streak (3) wipes the entire shared
   hash pool — set `--draft-min > 0` (default 0) or expect constant
   `low acceptance streak (3) - resetting ngram_mod`. `ngram-cache` has a per-slot
   reuse bug (PR #27852, open) where decode drops **below** the no-spec baseline
   (41.5 → 19.4 tok/s vs 25.9 for none) after a longer request precedes a shorter one
   on the same slot; `ngram-simple`/`map-k`/`mod` did not show this. Pin a build ≥
   PR #29924's fix if temp > 0 (truncated drafts were fully rejected; −26% tok/s).
5. Acceptance heuristic (PR #19164 comment, jacekpoplawski): *"a draft acceptance rate
   above 0.1 indicates some speedup."* Parse `draft acceptance rate` /
   `statistics ngram_mod: #calls, #gen drafts, #acc drafts...` from the server log.

**Does the PrismML fork carry these?** Yes in source: the `prism` branch has the
identical type map, all `--spec-ngram-*` flags in `common/arg.cpp`, and the five
`ngram-*.cpp` files. Release `prism-b10772-e8fd209` (2026-10-10) tracks upstream
closely. Practical check for a specific prebuilt: `llama-server --help | grep spec-type`.

---

## 2. Flag-based speed levers (ranked by confidence × effect)

These need no model file and no build change, and several matter *more* than
spec-decode on this hardware:

### 2.1 `-fa on`, never `auto`
`-fa auto` can resolve to disabled and cost 30–69% (PR #26460): the KV module is
allocated in flash-attention layout, then FA is turned off later and every decode step
materializes a full `transpose(v)`. RTX 4060 Ti **−30.4%** before, ~0 after.
https://github.com/ggml-org/llama.cpp/pull/26460

### 2.2 Never mismatched K/V types on a default CUDA build
Only `f16, q4_0, q8_0, bf16` have batched FA kernels; `q5_0/q5_1/q4_1` or **any K≠V
mismatch** silently runs the whole attention op on CPU — PR #28456: RTX 4080, 27B,
pp512 **1511 → 197 tok/s (8× slower) with no log output**. PR #27150 (merged) fixed
the silent fallback for the common mixed pairs (f16/q8_0, q8_0/q4_0, q4_0/q8_0:
pp512 ~380 → ~11200).
https://github.com/ggml-org/llama.cpp/pull/28456 ·
https://github.com/ggml-org/llama.cpp/pull/27150

### 2.3 KV quantization is a VRAM/context trade, NOT a speed lever
- **K/V asymmetry** (discussion #23470, Qwen2.5-7B-Q4_0 KLD): `f16/q4_0` (V-only quant)
  has mean KLD **0.004** / 96.9% same-top-p — **V at 4-bit costs nearly nothing**;
  `q4_0/f16` (K quantized) has KLD 5.487 / 11.8% same-top-p — *it's all in the K*.
  https://github.com/ggml-org/llama.cpp/discussions/23470
- **Decode cost of quantized KV grows with context** (A100, Qwen3-8B Q4_K_M,
  sotaaz.com/post/llamacpp-kv-cache-quantization-bench-en): @64K depth, q8_0 = **55%**
  of f16 decode, q4_0 = **50%**. q8_0 quality is inside the error bar at every length;
  q4_0 PPL +0.5–1.1%.
- Community (secondary, r/LocalLLaMA 1ng0fmv, RTX 5090): with `-ctk q4_0 -ctv q4_0`,
  90 tok/s PP / 10 tok/s TG @10K; **removing only the KV quant flags → 1,200 tok/s PP /
  35 tok/s TG @50K** — quantized KV forces random-access dequant that the GPU handles
  worse, so llama.cpp offloads it.

→ **For tok/s-max: keep f16 KV unless you need the context; if you quantize, quantize
V only, and prefer q8_0 over q4_0.** This project's `q8_0`-both-halves default is a
reasonable compromise, but a speed-first mode should reconsider K.

### 2.4 `-np 1`, `--no-mmap`, mlock is not a speed flag
- `-np 1` for interactive (2 slots turn a 2-min request into 3.5 min each);
  continuous batching is on by default since #6231.
- `--defrag-thold` is **deprecated** — defrag is on by default since #10233; don't
  expose it.
- mmap hurts prefill (secondary + discussion #29347): benefit is load time, not
  steady-state inference; OP reports mmap "kneecaps prefill by at least 30%".
- `--mlock` / `--hugepages`: no measured tok/s claim found in any source — treat as
  risk-reduction (pageout/OOM stability), not speed. `--hugepages` (PR #21821) is a
  kernel-vmemmap reclamation play, needs `sudo sysctl vm.nr_hugepages`.

### 2.5 MoE: the merged lever, and the UMA trap
- `--moe-cache-mib N` (merged 2026-10-07, **PR #29887**): GPU cache for CPU-resident
  experts — RTX 4090 **1.57–1.62×**, RTX 5090 **1.77×** decode on
  Qwen3.8-Flash-Next Q4_0. Default 0 = **disabled**, must be set explicitly. Not in
  the pinned prism-b10772 build. https://github.com/ggml-org/llama.cpp/pull/29887
- Partial offload on unified-memory iGPU is a trap (PR/issue #26876, Arc 140T):
  all-GPU tg128 18.49, CPU-only 12.19, `-ncmoe 40` split **5.68 tok/s (3.3× slower
  than all-GPU)** — fixed per-boundary overhead, not bandwidth. **Rule: on UMA/iGPU
  go all-GPU or all-CPU, never partial.**

### 2.6 ubatch is a correctness-visible parameter
An unmodified binary at `-ub 256` vs `-ub 512` **moves ~0.8% of greedy-argmax tokens**
(PR #27423 disclosure). Treat ubatch like the K/V split: re-verify determinism when
changing it. Adaptive ubatch shrink only helps with pipeline parallelism; single-device
pays the split for nothing (+10% pp512 lost on one MI210).
https://github.com/ggml-org/llama.cpp/pull/27423

---

## 3. Build-based levers (source build gains over the pinned prebuilt)

### 3.1 What a source build of current llama.cpp gains over prism-b10772-e8fd209
- `--moe-cache-mib` (#29887, +30112 multi-GPU) — 1.5–1.85× MoE decode
- CUDA graphs: #26802 (1.13–1.16× tg on RTX 5090 MoE parallel decode), #25749
  (Volta+Turing enabled, merged 2026-07-16), #28549 (MTP draft graphs)
- HIP: #26046 removed rocWMMA FlashAttention → better `fattn-mma-f16` kernel for AMD

### 3.2 sudoingX's PTQ1_0 mat-vec kernel — the cautionary tale for kernel claims
Branch `bonsai2` / `pr-ptq1-mmv` (PrismML PR #218). RTX 3060 12GB: tg128
**26.32 → 40.47 tok/s (+53%)**, fresh decode 26.4 → 40.5 (1.53×); 3060 Ti +33.8%;
4070 +10%. **RTX 3000 Ada Laptop 8GB: only +7%** — "stock decode already sits at
~153 GB/s of ~256, so there's no bottleneck to remove."
→ **A decode kernel is worth nothing on a card that's already bandwidth-saturated.**
The 5060 Ti Blackwell fixes (PDL race + flash-attn q4_0 V dequant stack spill, worth
up to +137% at 64K depth) are **already merged upstream** — free on a current build.
Source: https://github.com/sudoingX/local-ai-on-your-gaming-gpu (kernel/ dir, sweeps/)

---

## 4. Decision rules for the tool

1. **`-fa on` always; never `auto`.**
2. **Never mismatched K/V types; avoid q5_0/q5_1/q4_1 KV on a default CUDA build**
   (silent 8× prefill cliff). Prefer V-only quantization; q8_0 over q4_0.
3. **`-np 1` for interactive; don't expose `--defrag-thold`; `--mlock` is a stability
   flag, not a speed flag.**
4. **`--spec-type` is additive to the upstream `ngram-mod` default** — emit
   `--no-spec-type ngram-mod` when you don't want it; never assume a bare
   `--spec-type X` replaces it.
5. **Spec-decode selection is workload-gated, not model-gated.** n-gram drafting:
   neutral worst case on prose (30.03 vs 30.08), big win on repetition, and *negative*
   when the workload has no repetition and the build has the ngram-cache slot bug.
   Measure acceptance from the log; **< 0.10 = disable**. On our ternary Bonsai models
   specifically, PrismML issue #203 says n-gram **silently no-ops** — measure before
   trusting.
6. **Never enable ANY spec-decode on small-active MoE (A3B-class) on consumer
   Ampere** — every measured config was net-negative (−3% to −60%) even at 100%
   acceptance.
7. **On UMA/iGPU: all-GPU or all-CPU, never partial MoE offload.**
8. **Emit `--draft-min > 0`** for ngram-mod, or expect constant pool resets.
9. **ubatch changes numerics** — treat it as correctness-visible, not just a speed knob.
10. **The open gap (a PR angle for this project):** nobody has published whether
    n-gram spec pays on a **ternary PTQ1_0 model without a head**. The closest
    evidence (the MTP data) says the verify batch is what costs, and the mat-vec
    kernel is what fixed it. Our `bench` command can measure exactly this.

## Sources index

- llama.cpp upstream `master` (commit 1b70350c92, 2026-10-13): docs/speculative.md,
  common/speculative.cpp, tools/server/README.md
- PrismML-Eng/llama.cpp `prism` branch, release prism-b10772-e8fd209 (2026-10-10)
- PRs: #18471 #19164 #26046 #25749 #26802 #27150 #27423 #27210 #28391 #28456 #28549
  #29548 #29887 #29924 #30112
- Discussions: #23470 (K/V KLD), #29347 (mmap prefill), #20969 (TurboQuant, open)
- Issues: PrismML#203 (ngram no-op on Bonsai), upstream #26876 (UMA trap), #27852
  (ngram-cache slot bug), #26460 (fa auto)
- Secondary (lower confidence): r/LocalLLaMA 1ng0fmv, 1ri3mxa, 1satxjp, 1t8t0dx,
  1uyg3za; hackmd.io/ODXuOQNzSiyUITz7g9mtBw (3090 MoE negative matrix);
  sotaaz.com KV-quant benchmark; sudoingX sweeps/
