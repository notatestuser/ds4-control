# SSD Streaming Support — Design

**Date:** 2026-08-12
**Status:** Approved (2026-08-12)

## Goal

Let ds4-control run `ds4-server` with SSD streaming enabled by default, freeing
~15 GiB of resident model weights (moved to SSD). Expose it as a Settings
toggle with an expert-cache budget slider, defaulted to the value that frees
~15 GiB on the selected model.

## Background

`ds4-server` (antirez/ds4, vendored at `external/ds4`) supports SSD-backed
model streaming (`--ssd-streaming`): non-routed weights stay resident while
routed MoE experts live in an in-memory cache and load from the GGUF on cache
misses. The routed-expert cache budget is `--ssd-streaming-cache-experts
NGB` (memory budget) or `N` (exact expert count). A plain `--ssd-streaming`
uses an automatic budget of 80% of the backend's recommended working set
minus non-routed weights — on this machine (M5 Max, 128 GiB, Metal
recommended working set 107.5 GiB) that frees only ~5 GiB, so an explicit
budget is required to reach the ~15 GiB target.

### Measured model facts (q2-q4 0731, the default on ≥128 GiB machines)

Parsed from the downloaded GGUF metadata (`DeepSeek-V4-Flash-...-fixed-0731.gguf`):

| Tensor family | Size |
|---|---|
| `ffn_down_exps` (routed) | 31.0 GiB |
| `ffn_gate_exps` (routed) | 25.8 GiB |
| `ffn_up_exps` (routed) | 25.8 GiB |
| **Total routed experts** | **82.7 GiB** |
| Non-routed (attn, embeddings, shared FFN, norms) | ~8.3 GiB |
| Total | ~91 GiB (matches file size) |

Freeing ~15 GiB ⇒ expert-cache budget ≈ **67 GB**
(`--ssd-streaming-cache-experts 67GB`), freeing 82.7 − 67 ≈ 15.7 GiB. ds4 may
cap an explicit budget down (7/8 of recommended working set minus context
memory), which only increases the amount freed; its startup log reports the
actual cache size ("streaming expert cache budget=… target=… GiB").

## Decisions

- **Default ON.** Fresh installs run with SSD streaming enabled and the
  ~15 GiB-free budget. Users can toggle off or dial the budget back toward
  "keep more in RAM" if cache-miss decode feels slow.
- **Per-quant default budget** so "frees ~15 GiB" holds for any Flash quant
  (q2: 58 GB, q2-q4: 67 GB, q4: 130 GB) and Pro (409 GB). Derived from a
  small hardcoded `routedExpertGiB` table on `Quant` (q2-q4 measured from the
  GGUF; others estimated as weights minus ~8 GiB non-routed).
- **One persisted budget value** (not per-quant keyed). If the user changes
  quant, the saved budget is kept — their explicit choice. The Settings
  caption shows the effective freed amount for the currently selected quant.
- **UI lives in Settings** (matches existing Toggle+Slider row pattern),
  applied by the existing Apply/Restart flow. No popup changes.
- **Out of scope:** relaxing the RAM feasibility gate to run Pro below
  512 GiB (ds4 supports streaming Pro on 128 GiB, but not requested);
  `--ssd-streaming-cold` / `--ssd-streaming-preload-experts` (measurement-only);
  per-quant persisted budgets; runtime GGUF parsing for exact expert bytes
  (ds4's log + safety cap absorb estimation error).

## Changes

### 1. `Model/Variant.swift`

Add to `Quant`:

```swift
/// Routed-expert tensor bytes (GiB) — the weights SSD streaming can push to
/// disk. q2-q4 measured from the 0731 GGUF metadata; others estimated as
/// total weights minus ~8 GiB non-routed (attn/embeddings/shared FFN).
var routedExpertGiB: Double {
    switch self {
    case .proImatrix: return 424
    case .q4Imatrix: return 145
    case .q2Imatrix: return 73
    case .q2q4Imatrix: return 82.69
    }
}

/// Default SSD-streaming expert-cache budget (GiB) for this quant: leaves
/// ~15 GiB of resident routed experts to stream from SSD. Floor 16 GiB so a
/// degenerate tiny cache can never be configured accidentally.
var defaultStreamingCacheGB: Int { max(16, Int(routedExpertGiB - 15)) }  // truncates: 82.69−15 → 67
```

### 2. `AppState.swift`

Follow the existing `@Published` + `didSet` persistence pattern:

```swift
/// SSD streaming: cache only `ssdStreamingCacheGB` of routed experts in RAM;
/// the rest stream from the GGUF on demand. Default ON with the ~15 GiB-free
/// budget for the default quant.
@Published var ssdStreaming: Bool { didSet { d.set(ssdStreaming, forKey: "ssdStreaming") } }
@Published var ssdStreamingCacheGB: Int {
    didSet { d.set(ssdStreamingCacheGB, forKey: "ssdStreamingCacheGB") }
}
```

`init` read-back: `ssdStreaming = d.object(forKey: "ssdStreaming") as? Bool ?? true`
(default on); `ssdStreamingCacheGB` defaults to
`Quant.for(selectedVariant, flashQuant: selectedFlashQuant).defaultStreamingCacheGB`
when unset (compute after the quant/variant read-backs), else the stored value.

### 3. `Services/SupervisorService.swift`

Extend `start(...)` and `restart(...)` with defaulted params
`ssdStreaming: Bool = false, ssdStreamingCacheGB: Int = 0`. In the args
assembly (after the `--metal` block):

```swift
if ssdStreaming {
    args += ["--ssd-streaming"]
    if ssdStreamingCacheGB > 0 {
        args += ["--ssd-streaming-cache-experts", "\(ssdStreamingCacheGB)GB"]
    }
}
```

### 4. Call sites (thread `app.ssdStreaming` / `app.ssdStreamingCacheGB`)

- `Views/ModelRowView.swift` — two `supervisor.start(...)` calls
- `Views/ThinkingModeControls.swift` — one `supervisor.restart(...)` call
- `Views/SettingsView.swift` — `restart()` helper

### 5. `Views/SettingsView.swift` — new section

New section following the existing Toggle + Slider row pattern:

- Toggle: "Stream expert weights from SSD"
- When on: slider, range `16...(max(17, Int(quant.routedExpertGiB) - 1))`, step 1,
  plus a caption computing freed RAM for the currently selected quant:
  `"Expert cache \(gb) GiB — frees ~\(Int((quant.routedExpertGiB - Double(gb)).rounded())) GiB of RAM. Decode can be slower when the SSD must refill the cache."`
- Footer note explaining the tradeoff; changes apply via the existing
  Apply/Restart flow.

## Tests

- `SupervisorStateMachineTests` (or the existing fake-runner integration
  tests): `start` with `ssdStreaming: true, ssdStreamingCacheGB: 67` passes
  `--ssd-streaming` and `--ssd-streaming-cache-experts 67GB`; with `false`
  passes neither.
- `VariantTests`: `defaultStreamingCacheGB` per quant (q2-q4 → 67, q2 → 58,
  q4 → 130, pro → 409); floor of 16.
- `AppState` default assertions: fresh install → `ssdStreaming == true`,
  `ssdStreamingCacheGB == 67` (default quant q2-q4 on ≥128 GiB).
- All existing tests keep passing (new params defaulted).

## Manual verification

Launch `ds4-server` with the real q2-q4 model and the flags
(`-m <gguf> --ctx 1000000 --metal --ssd-streaming
--ssd-streaming-cache-experts 67GB`), read the startup cache report line, and
compare resident memory vs. a non-streaming launch: expect ~15 GiB less
resident RAM. The app's stderr tail (`recentLog`) surfaces the same report.
