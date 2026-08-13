# Laguna S 2.1 Support — Design

**Date:** 2026-08-12
**Status:** Approved in conversation (2026-08-12); written for review
**Branch/worktree:** `feat/laguna` at `.worktrees/feat-laguna` (forked from `feat/ssd-streaming`)

## Goal

Let DS4 Control install and serve **Laguna S 2.1 (q2-q3)** alongside DS4F (V4 Pro / V4 Flash), with switching between them via the existing restart flow. Primary target: **64 GB-class laptops**, where q2-q3 is the only feasible model. The app continues to supervise one `ds4-server` at a time.

## Decisions (all settled in conversation)

1. **One new model: `laguna-q2-q3`** (`laguna-s-2.1-RoutedQ2_K-Last27Q3_K.gguf`, 44.95 GiB). No `laguna-q4`, no other Laguna quants.
2. **No DFlash.** The draft-model download, `--dflash` plumbing, and greedy-temperature interplay are deferred — the user hasn't validated DFlash's value, and DFlash is mutually exclusive with SSD streaming upstream.
3. **Combined fork branch.** `laguna-s2.1` was merged into `ds4-control-patches-v2` as **`ds4-control-patches-v3`**; 15 conflict files resolved; the merged `ds4-server` **builds clean and was boot-validated against the real q2-q3 GGUF** (served `/v1/models` as `laguna-s-2.1`, generated a completion; KV report 2.36 GiB @ 50k matched the research formula). The app's submodule pin moves to this branch. The THINK_MAX 0731-prefix fix is retained.
4. **SSD streaming is DS4F-only.** ds4 hard-refuses `--ssd-streaming` for Laguna S 2.1 ("not implemented … yet", `ds4_engine_open_internal`, no env override) — the server won't start. The app must never pass the flag for Laguna; the Settings toggle shows N/A for Laguna. The Stage-1 default-ON setting must not break Laguna launches.
5. **Built-in chat works for Laguna, thinking-mode picker hidden.** No Instant/Standard/Max Think toggle for Laguna (DS4F semantics, 393,216 floor); the chat sends no thinking override and renders whatever ds4 emits. A live SSE smoke test verifies the reasoning shape during implementation.
6. **Unified model picker.** A `Model` (family × quant) replaces the variant/quant pair as the app's identity. The popup lists feasible models (name + resident size); Settings' model section generalizes; switching = restart (full reload).
7. **Feasibility floor 64 GiB; default ctx 50,000; `--prefill-chunk 4096` for Laguna.** q2-q3 all-resident needs ~51 GiB planned with the bounded chunk (weights 44.95 + KV 2.36 @ 50k + scratch ~1.5 + buffers ~2); the default prefill 16384 costs ~5.9 GiB of scratch and pushes 64 GB machines into the pressure zone. Wired-limit advisory applies to the 64–95 GiB band.
8. **Per-model download metadata.** `downloadRepo = "antirez/Laguna-S-2.1-GGUF"`, `downloadRevision = "main"`, `weightsGiB = 44.95` (measured from the GGUF on disk). `HFDownloader` (already supports `revision:`) is constructed per `download()` from model metadata; the injectable fetch closure signature is unchanged. Cleanup is family-scoped; the pre-0731 legacy migration stays DS4F-only.

## Model facts (measured from the GGUF on disk, 2026-08-12)

| Field | Laguna S 2.1 q2-q3 |
|---|---|
| File | `laguna-s-2.1-RoutedQ2_K-Last27Q3_K.gguf` (44.95 GiB) |
| Blocks / sparse layers | 48 blocks, 1 leading dense → 47 sparse |
| Global layers (`il%4==0`) / SWA (window 512) | 12 / 36 |
| Routed expert tensors | **40.87 GiB** (gate 13.62 + up 13.62 + down 13.62) |
| Non-routed | ~4.1 GiB (attn 2.77 + embeddings/shared FFN ~1.3) |
| Per-layer expert classes | 0.738 GiB (Q2_K) vs 0.967 GiB (Q3_K) — **mixed** |
| KV @ 50k ctx | 2.36 GiB (formula + boot-verified) |
| Graph scratch @ 50k, prefill 16384 / 4096 | ~5.9 GiB / ~1.5 GiB |
| Model id | `laguna-s-2.1` |
| Context ceiling | **262,144** (`laguna.context_length` GGUF key) |

## Changes

### 1. `Model` abstraction (`Model/Variant.swift` + new `Model/Model.swift`)

A `Model` fully determines identity and behavior. Represent as an enum of the runnable models:

- `v4Pro`, `v4Flash(q2/q2q4/q4)`, `lagunaS21` (q2-q3)

Per-model members (mirroring/absorbing the existing `Variant`/`Quant`/`FlashQuant` surface):

```swift
var displayName: String            // "V4 Pro", "V4 Flash", "Laguna S 2.1"
var modelId: String                // "deepseek-v4-pro", "deepseek-v4-flash", "laguna-s-2.1"
var layers: Int
var ctxCeiling: Int                // Laguna 262,144 (GGUF metadata); DS4F 1,000,000
var weightsGiB: Double             // 432 / 153 / 81 / 91 / 44.95
var downloadRepo: String           // "antirez/deepseek-v4-gguf" | "antirez/Laguna-S-2.1-GGUF"
var downloadRevision: String       // "main" for all current models
var ggufFilename: String
var supportsSSDStreaming: Bool     // DS4F true; Laguna false (hard ds4 gate)
var supportsThinkingModes: Bool    // DS4F true; Laguna false (v1)
var defaultCtx(ramGiB:) -> Int     // DS4F existing tiers; Laguna 50,000
var defaultPrefillChunk: Int?      // Laguna 4096; DS4F nil (ds4 default)
var feasibility(ramGiB:) -> Feasibility
var routedExpertGiB: Double?       // DS4F quants (SSD-streaming table); nil for Laguna
```

Keep `Variant`/`Quant`/`FlashQuant` where the existing download/feasibility code keys off them, or fold them into `Model` — the plan picks the migration that touches the fewest call sites while delivering the unified picker.

### 2. `AppState`

- Replace the `selectedVariant`/`selectedFlashQuant` pair with `selectedModel: Model` (persisted by raw value), or keep the pair and add `selectedFamily` — the plan chooses the shape that makes the unified picker and family gates least invasive, defaulting to a single `selectedModel`.
- `ssdStreaming`/`ssdStreamingCacheGB` (Stage 1) stay global; the launch layer gates them per model.

### 3. `SupervisorService`

`start()`/`restart()` args become model-family-aware:

- gguf path from `model.ggufFilename` (no change in mechanics)
- `--ssd-streaming`/`--ssd-streaming-cache-experts` **only when `model.supportsSSDStreaming && app.ssdStreaming`**
- `--prefill-chunk 4096` **only for Laguna**
- `download(...)` builds `HFDownloader(repo: model.downloadRepo, revision: model.downloadRevision)` per call; `SupervisorService.ggufRepo` static removed
- cleanup generalized: "keep the selected model, delete other quants of the same family; never touch the other family"

### 4. `Feasibility` + default ctx

- Laguna q2-q3 tier: `< 64 GiB` blocked; `64–95 GiB` `.warnWiredLimit` (default GPU wired limit ~0.67×RAM ≈ 43 GiB < 44.95 GiB weights — must be raised); `≥ 96 GiB` `.standard`.
- `defaultCtx`: Laguna 50,000 across tiers (ctx override remains; KV is SWA-capped so context is cheap; scratch is bounded by the prefill chunk).

### 5. Chat + agents

- `ChatViewModel` model id bound to the running server (already done for adopted servers) so family switches don't leave a stale DS4F id.
- Thinking-mode picker hidden when `!model.supportsThinkingModes`; chat sends no thinking override for Laguna.
- `AgentLauncher` family-aware: Laguna gets its model id + context window and no DS4F Max-Think prompt.
- Verify the live SSE shape for Laguna (reasoning interleaving) during implementation.

### 6. Submodule pin

- Point `external/ds4` at `ds4-control-patches-v3` (currently `d0b0caa` in the worktree). **The branch must be pushed to the fork** (`notatestuser/ds4`) before CI (`submodules: recursive`) and release builds can resolve it.
- The app-side pin change is one line (`git -C external/ds4 ...` + commit the `.gitmodules`/submodule pointer), staged after the fork branch is pushed.

## Out of scope

- `laguna-q4`, `Laguna XS`, other Laguna builds
- DFlash download/`--dflash`/greedy-temperature plumbing (deferred; captured: ds4 supports DFlash for Laguna on Metal, but it's mutually exclusive with SSD streaming)
- SSD streaming for Laguna (ds4 hard gate — no app workaround)
- Relaxing the DS4F gates (Flash ≥96, Pro ≥512) to enable streaming-based fits — not requested
- Per-model persisted SSD-streaming budgets (single global budget, as in Stage 1)

## Tests

- `Model` table: displayName/modelId/weightsGiB/downloadRepo/ggufFilename/supports* per model; Laguna weightsGiB = 44.95
- Feasibility: Laguna tiers (64 floor, wired-limit band, standard band); `defaultCtx` 50,000
- Supervisor args: Laguna launch passes `--prefill-chunk 4096`, never `--ssd-streaming` even when `ssdStreaming` is on; DS4F behavior unchanged; download uses the Laguna repo+filename
- Downloader: second repo (`antirez/Laguna-S-2.1-GGUF`) fetch path
- AppState: `selectedModel` persistence; `ssdStreaming` still defaults on but is inert for Laguna
- Source tests: thinking-picker gating and SSD-section N/A state for Laguna
- All Stage-1 tests keep passing

## Manual verification

- Live boot of q2-q3 via the app path (already proven with the merged binary): KV report, `/v1/models` model id, one generation
- SSE smoke test for the chat reasoning shape
- 64 GB-class feasibility math (planned ~51 GiB with `--prefill-chunk 4096`); wired-limit advisory shows for 64–95 GiB
- `--ssd-streaming` refusal confirmed for Laguna (server refuses; app never sends it)
