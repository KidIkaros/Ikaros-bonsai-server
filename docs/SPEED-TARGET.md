# Intelligent Local-AI Optimizer — design

## Goal
Maximize achievable tok/s for whatever model the user selects, on whatever hardware they
own. 100 tok/s is the ideal mark, not a gate — push the boundary, measured not assumed.

The user states a desire; the system understands the hardware, pushes it, discovers the
best models, and emits the fastest honest serve config. Complexity (quant, backend, KV
type, MTP n-max, ctx) stays inside the tool.

## Principles
1. **Push the boundary** — measure, don't assume
2. **Backend-agnostic** — best backend wins per model; ROCm is not sacred
3. **Hardware-aware** — capability discovery + bandwidth model
4. **Model-agnostic** — discover from HuggingFace, not a fixed catalog
5. **Honest** — measured beats estimated; estimates only pre-filter

## Architecture — four layers

```
User intent ("fastest 30B coder under 12GB")
    ↓
[L4 Intent]  → constraints (task, size, speed)
    ↓
[L2 Discovery]  HF API search → candidates (GGUF, fork-loadable)
    ↓
[L1 Hardware]   BW, VRAM, working backends, η
    ↓
[L3 Optimizer]  ceiling estimate → filter/rank → per-model tune (both backends)
    ↓
[Apply]         service.env + start-server (best backend, best config)
```

### L1 Hardware capability model (`hardware.sh` / detect)
- Backend probe: which backends actually work (rocm / vulkan / cpu)
- VRAM + RAM budget (exists)
- Bandwidth calibration: BW×η from one measured model on this card
- Backend efficiency notes (e.g. Vulkan > ROCm for MTP speculative on Radeon)

### L2 Model discovery (`discover.sh` — new)
- HF API: search by task, name, size, popularity, recency
- Filter: GGUF quants the PrismML fork can load (Q1_0/Q2/PQ2_0/PTQ1_0/iq_*/...)
- Weight bytes/token → ceiling via L1 formula
- Quality signals: downloads, likes, release recency, size sweet spot

### L3 Config optimizer (`assess.sh --tune` — mostly exists)
- Per model × backend: KV type, ubatch, NGL, MTP n-max, ctx
- **New: backend is a tuned dimension** — run both, pick the winner

### L4 Intent → recommendation (`bonsai recommend` — new)
- Parse intent → constraints → discover → filter → rank → emit config → apply

## Measured data — RX 9060 XT (288 GB/s, 16 GB, ROCm 7.2 + Vulkan/radv)

| Model | Backend | single | +MTP n-max 2 | notes |
|---|---|---|---|---|
| Bonsai-1.7B Q1_0 (0.24G) | Vulkan | 198 | 349 | ✅ >100 |
| Bonsai-8B Q1_0 (1.16G) | Vulkan | 108 | 123 | ✅ >100 |
| 27B PTQ1_0-lean MTP (5.9G) | Vulkan | 35.3 | **54.9** | boundary push: n-max 3–5 in flight |
| 27B PQ2_0 (6.7G) | Vulkan | 32.7 | ~55 | |
| 27B IQ4_XS MTP (13.3G) | ROCm | 19.4 | 29.0 | ROCm-vs-Vulkan comparison in flight |

Physics: `tok/s ≈ (BW×η)/W`, ×~1.6 with draft-mtp n-max 2. 27B on this card caps ~55;
>100 needs ≤~2.2 GB weights (8B and below). Bigger cards scale BW only.

## Phases
1. **Backend comparison + boundary push** (running) — ROCm vs Vulkan on PTQ1_0-lean;
   MTP n-max 3/4/5
2. **L1 hardware model** — backend probe + bandwidth calibration fn
3. **L4 recommend** — ceiling estimator + catalog walk + config emit
4. **L2 discovery** — HF search + GGUF filter + ranking
5. **Full intent pipeline** + UX

## Known constraints (honored)
- PrismML fork only; HIP/ROCm for gfx1200 (`HSA_OVERRIDE_GFX_VERSION=12.0.0`)
- Vulkan is a first-class backend (radv warning is benign)
- No sudoingX CUDA PTQ1_0 kernel port (3.6× slower on HIP — HARDWARE.md)
- Non-MTP 27B files get no MTP speedup — prefer MTP/lean variants when they exist
