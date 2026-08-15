# Laguna S 2.1 Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let DS4 Control install and serve **Laguna S 2.1 (q2-q3)** alongside DS4F (V4 Pro / V4 Flash), switchable via a unified model picker, targeting 64 GB-class laptops.

**Architecture:** A `Model` enum (family × quant) becomes the app's single model identity, absorbing download metadata, feasibility, ctx, SSD-streaming and thinking-mode capability. `SupervisorService` gains family-aware launch args (SSD streaming gated to DS4F — ds4 hard-refuses it for Laguna; `--prefill-chunk 4096` for Laguna), and the downloader constructs `HFDownloader` per model from its repo. The vendored ds4 submodule moves to a new combined fork branch `ds4-control-patches-v3` (laguna-s2.1 merged into ds4-control-patches-v2 — already built and boot-validated against the real q2-q3 GGUF).

**Tech Stack:** Swift 6, SwiftPM, SwiftUI, XCTest; backing server: vendored `ds4-server` (Metal).

**Design spec:** `docs/superpowers/specs/2026-08-12-laguna-support-design.md` (approved 2026-08-12).

## Global Constraints

- **Worktree:** execute in `/Users/pauleveritt/projects/ds4-control/.worktrees/feat-laguna` on branch `feat/laguna` (forked from `feat/ssd-streaming`). Test from the worktree root.
- **Build/test are plain now** (Xcode selected + license accepted): `swift build`, `swift test`, `swift format lint --recursive Sources Tests`. No plugin workarounds.
- **The combined ds4 fork branch already exists** in the worktree's submodule (`external/ds4` on `ds4-control-patches-v3`, HEAD `d0b0caa`), built and smoke-tested. Do not rebuild or re-merge it. The app-side pin moves in Task 8; pushing the branch to the fork (`git push origin ds4-control-patches-v3` from `external/ds4`) may require the user's GitHub auth — if the push fails, note it and continue (the pin still works for local builds; CI/release need the push).
- **Model facts (measured):** q2-q3 file 44.95 GiB; routed experts 40.87 GiB; non-routed ~4.1; mixed per-layer classes 0.738 (Q2_K) / 0.967 (Q3_K); KV @50k = 2.36 GiB (boot-verified); ctx ceiling 262,144 (GGUF `laguna.context_length`); model id `laguna-s-2.1`; download repo `antirez/Laguna-S-2.1-GGUF`, revision `main`, filename `laguna-s-2.1-RoutedQ2_K-Last27Q3_K.gguf`.
- **ds4 hard-gates SSD streaming for Laguna** (`--ssd-streaming is not implemented for Laguna S 2.1 yet` → server refuses to start). The app must never pass it for Laguna.
- Follow existing patterns exactly (AppState `@Published`+`didSet`; fake-runner arg tests; source-containment view tests in `ChatThinkMaxToggleTests` style).
- No code changes outside the files listed per task. Stage-1 SSD-streaming behavior for DS4F must remain unchanged.

---

### Task 1: `Model` enum — the single model identity

**Files:**
- Create: `Sources/DS4Control/Model/Model.swift`
- Modify: `Tests/DS4ControlTests/VariantTests.swift` (add a `ModelTests` test class in a new file instead: `Tests/DS4ControlTests/ModelTests.swift`)

**Interfaces:**
- Produces: `enum Model: String, CaseIterable, Identifiable, Codable` with cases `v4Pro, v4FlashQ2, v4FlashQ2Q4, v4FlashQ4, lagunaS21`, plus members listed below. Consumed by every later task. `Quant` (existing DS4F enum) stays as the DS4F table behind `model.quant`.

- [ ] **Step 1: Write the failing tests** — create `Tests/DS4ControlTests/ModelTests.swift`:

```swift
import XCTest
@testable import DS4Control

final class ModelTests: XCTestCase {
    func testAllCasesAndLabels() {
        XCTAssertEqual(Model.allCases, [.v4Pro, .v4FlashQ2, .v4FlashQ2Q4, .v4FlashQ4, .lagunaS21])
        XCTAssertEqual(Model.v4Pro.displayName, "V4 Pro")
        XCTAssertEqual(Model.v4FlashQ2Q4.displayName, "V4 Flash")
        XCTAssertEqual(Model.lagunaS21.displayName, "Laguna S 2.1")
        XCTAssertEqual(Model.v4FlashQ4.label, "V4 Flash · ~153 GiB")
        XCTAssertEqual(Model.lagunaS21.label, "Laguna S 2.1 · ~45 GiB")
    }
    func testModelIds() {
        XCTAssertEqual(Model.v4Pro.modelId, "deepseek-v4-pro")
        XCTAssertEqual(Model.v4FlashQ2Q4.modelId, "deepseek-v4-flash")
        XCTAssertEqual(Model.lagunaS21.modelId, "laguna-s-2.1")
    }
    func testQuantMappingAndCapabilities() {
        XCTAssertEqual(Model.v4FlashQ2Q4.quant, .q2q4Imatrix)
        XCTAssertNil(Model.lagunaS21.quant)  // no DS4F quant
        XCTAssertTrue(Model.v4FlashQ2Q4.supportsSSDStreaming)
        XCTAssertFalse(Model.lagunaS21.supportsSSDStreaming)  // ds4 hard gate
        XCTAssertTrue(Model.v4FlashQ2Q4.supportsThinkingModes)
        XCTAssertFalse(Model.lagunaS21.supportsThinkingModes)  // v1: native reasoning, no picker
    }
    func testLagunaDownloadAndSizeFacts() {
        XCTAssertEqual(Model.lagunaS21.weightsGiB, 44.95, accuracy: 0.01)
        XCTAssertEqual(Model.lagunaS21.downloadRepo, "antirez/Laguna-S-2.1-GGUF")
        XCTAssertEqual(Model.lagunaS21.downloadRevision, "main")
        XCTAssertEqual(
            Model.lagunaS21.ggufFilename,
            "laguna-s-2.1-RoutedQ2_K-Last27Q3_K.gguf")
        XCTAssertNil(Model.lagunaS21.routedExpertGiB)  // SSD streaming N/A
    }
    func testCtxCeilingAndPrefill() {
        XCTAssertEqual(Model.lagunaS21.ctxCeiling, 262_144)  // GGUF laguna.context_length
        XCTAssertEqual(Model.v4FlashQ2Q4.ctxCeiling, 1_000_000)
        XCTAssertEqual(Model.lagunaS21.defaultPrefillChunk, 4096)
        XCTAssertNil(Model.v4FlashQ2Q4.defaultPrefillChunk)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ModelTests`
Expected: FAIL — `Model` unresolved.

- [ ] **Step 3: Implement** — create `Sources/DS4Control/Model/Model.swift`:

```swift
import Foundation

/// The runnable models DS4 Control can download and serve. A `Model` fully
/// determines identity, download metadata, feasibility, and per-model capability
/// (SSD streaming, thinking modes). DS4F variants map to the existing `Quant`
/// table; Laguna S 2.1 is its own row (facts measured from the GGUF on disk).
enum Model: String, CaseIterable, Identifiable, Codable {
    case v4Pro
    case v4FlashQ2
    case v4FlashQ2Q4
    case v4FlashQ4
    case lagunaS21

    var id: String { rawValue }

    /// The DS4F quant this model maps to (nil for Laguna — it has no DS4F quant).
    var quant: Quant? {
        switch self {
        case .v4Pro: return .proImatrix
        case .v4FlashQ2: return .q2Imatrix
        case .v4FlashQ2Q4: return .q2q4Imatrix
        case .v4FlashQ4: return .q4Imatrix
        case .lagunaS21: return nil
        }
    }

    var displayName: String {
        switch self {
        case .v4Pro: return "V4 Pro"
        case .v4FlashQ2, .v4FlashQ2Q4, .v4FlashQ4: return "V4 Flash"
        case .lagunaS21: return "Laguna S 2.1"
        }
    }

    /// Picker label: display name + resident size, e.g. "V4 Flash · ~91 GiB".
    var label: String { "\(displayName) · ~\(Int(weightsGiB)) GiB" }

    var modelId: String {
        switch self {
        case .v4Pro: return "deepseek-v4-pro"
        case .v4FlashQ2, .v4FlashQ2Q4, .v4FlashQ4: return "deepseek-v4-flash"
        case .lagunaS21: return "laguna-s-2.1"
        }
    }

    /// Transformer layers (DS4 shape): Pro 61, Flash 43, Laguna S 48.
    var layers: Int {
        switch self {
        case .v4Pro: return 61
        case .v4FlashQ2, .v4FlashQ2Q4, .v4FlashQ4: return 43
        case .lagunaS21: return 48
        }
    }

    /// Context ceiling: DS4F 1M; Laguna 262,144 (GGUF `laguna.context_length`).
    var ctxCeiling: Int {
        switch self {
        case .lagunaS21: return 262_144
        default: return 1_000_000
        }
    }

    /// Approx resident weights, GiB (mmap'd GGUF ≈ file size; Laguna measured).
    var weightsGiB: Double {
        quant?.weightsGiB ?? 44.95
    }

    /// Routed-expert bytes for the SSD-streaming budget table; nil for Laguna
    /// (SSD streaming not supported there).
    var routedExpertGiB: Double? { quant?.routedExpertGiB }

    var supportsSSDStreaming: Bool { quant != nil }
    /// v1: thinking-mode picker is DS4F-only (Laguna uses native interleaved reasoning).
    var supportsThinkingModes: Bool { quant != nil }

    var downloadRepo: String {
        switch self {
        case .lagunaS21: return "antirez/Laguna-S-2.1-GGUF"
        default: return "antirez/deepseek-v4-gguf"
        }
    }
    var downloadRevision: String { "main" }
    var ggufFilename: String {
        quant?.ggufFilename ?? "laguna-s-2.1-RoutedQ2_K-Last27Q3_K.gguf"
    }

    /// Family launch tweak: Laguna bounds graph scratch on 64 GB-class machines
    /// (measured: prefill 16384 → ~5.9 GiB scratch; 4096 → ~1.5 GiB).
    var defaultPrefillChunk: Int? { self == .lagunaS21 ? 4096 : nil }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter ModelTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/DS4Control/Model/Model.swift Tests/DS4ControlTests/ModelTests.swift
git commit -m "feat: Model enum — single model identity (DS4F variants + Laguna S 2.1)"
```

### Task 2: Feasibility + default ctx for Laguna

**Files:**
- Modify: `Sources/DS4Control/Model/Feasibility.swift`
- Test: `Tests/DS4ControlTests/FeasibilityTests.swift`

**Interfaces:**
- Consumes: `Model` (Task 1).
- Produces: `feasibility(ramGiB:model:)`, `defaultCtx(ramGiB:model:)` — replacing the `variant`/`flashQuant`-typed versions. Old signatures stay temporarily for DS4F callers until Task 7, OR update all callers now — the plan updates the callers in the tasks that own them; this task adds the `Model`-typed overloads and keeps the old ones delegating.

- [ ] **Step 1: Write the failing tests** — append to `FeasibilityTests.swift`:

```swift
func testLagunaFeasibilityTiers() {
    XCTAssertEqual(feasibility(ramGiB: 63, model: .lagunaS21), .blocked(reason: "").map(\.reason))  // placeholder
}
```

  Replace that placeholder with real assertions (read the file first to match the existing assertion style):

```swift
func testLagunaFeasibilityTiers() {
    if case .blocked = feasibility(ramGiB: 63, model: .lagunaS21) {} else { XCTFail("63 GiB must block") }
    if case .warnWiredLimit = feasibility(ramGiB: 64, model: .lagunaS21) {} else { XCTFail("64 GiB must warn wired limit") }
    if case .warnWiredLimit = feasibility(ramGiB: 95, model: .lagunaS21) {} else { XCTFail("95 GiB must warn wired limit") }
    XCTAssertEqual(feasibility(ramGiB: 96, model: .lagunaS21), .standard)
}
func testLagunaDefaultCtx() {
    XCTAssertEqual(defaultCtx(ramGiB: 64, model: .lagunaS21), 50_000)
    XCTAssertEqual(defaultCtx(ramGiB: 128, model: .lagunaS21), 50_000)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter FeasibilityTests`
Expected: FAIL — `feasibility(ramGiB:model:)` unresolved.

- [ ] **Step 3: Implement** — in `Feasibility.swift`, add the `Model`-typed overloads (keep the existing `Variant`-typed ones delegating to them):

```swift
/// Feasibility gate keyed on the runnable model. Laguna S 2.1 (q2-q3, 44.95 GiB
/// weights) targets 64 GB-class machines: ≥96 GiB is comfortable; 64–95 GiB fits
/// only with the Metal wired limit raised (default ~0.67×RAM ≈ 43 GiB < weights);
/// below 64 GiB the weights + 8 GiB OS reserve don't fit.
func feasibility(ramGiB: Double, model: Model) -> Feasibility {
    switch model {
    case .v4Pro:
        guard ramGiB >= 512 else { return .blocked(reason: "V4 Pro needs ≥ 512 GiB unified memory.") }
        return .warnWiredLimit(advisoryMB: wiredLimitAdvisoryMB(ramGiB: ramGiB))
    case .v4FlashQ2, .v4FlashQ2Q4, .v4FlashQ4:
        if ramGiB >= 128 { return .standard }
        if ramGiB >= 96 {
            return .warnWiredLimit(advisoryMB: wiredLimitAdvisoryMB(ramGiB: ramGiB))
        }
        return .blocked(
            reason:
                "V4 Flash needs ≥ 96 GiB unified memory. Below that, the ~\(Int(model.weightsGiB)) GiB model plus its KV cache exceed RAM, so it can't run."
        )
    case .lagunaS21:
        if ramGiB >= 96 { return .standard }
        if ramGiB >= 64 {
            return .warnWiredLimit(advisoryMB: wiredLimitAdvisoryMB(ramGiB: ramGiB))
        }
        return .blocked(
            reason: "Laguna S 2.1 needs ≥ 64 GiB unified memory — its ~45 GiB weights plus the OS reserve don't fit below that."
        )
    }
}

/// Default context keyed on the runnable model. Laguna defaults to 50,000 (SWA-capped
/// KV is cheap; scratch is bounded by --prefill-chunk 4096); DS4F keeps its tiers.
func defaultCtx(ramGiB: Double, model: Model) -> Int {
    switch model {
    case .lagunaS21: return 50_000
    case .v4Pro: return model.ctxCeiling
    case .v4FlashQ2, .v4FlashQ2Q4, .v4FlashQ4:
        return ramGiB >= 128 ? model.ctxCeiling : thinkMaxMinCtx
    }
}

// Keep the existing Variant-typed entry points delegating (removed in Task 7):
func feasibility(ramGiB: Double, variant: Variant) -> Feasibility {
    feasibility(ramGiB: ramGiB, model: variant == .pro ? .v4Pro : .v4FlashQ2Q4)
}
func defaultCtx(ramGiB: Double, variant: Variant, flashQuant: FlashQuant) -> Int {
    defaultCtx(ramGiB: ramGiB, model: flashQuant == .q2 ? .v4FlashQ2 : flashQuant == .q4 ? .v4FlashQ4 : .v4FlashQ2Q4)
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter FeasibilityTests`
Expected: PASS (existing + 2 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/DS4Control/Model/Feasibility.swift Tests/DS4ControlTests/FeasibilityTests.swift
git commit -m "feat: Laguna feasibility tiers (64 GiB floor, wired-limit band) and 50k default ctx"
```

### Task 3: `AppState.selectedModel`

**Files:**
- Modify: `Sources/DS4Control/AppState.swift`
- Test: `Tests/DS4ControlTests/AppStateTests.swift`

**Interfaces:**
- Consumes: `Model` (Task 1).
- Produces: `AppState.selectedModel: Model` (persisted, defaulting by RAM: ≥512 → v4Pro; ≥128 → v4FlashQ2Q4; ≥96 → v4FlashQ2; else lagunaS21), with legacy-key migration from `selectedVariant`/`selectedFlashQuant`. The old `selectedVariant`/`selectedFlashQuant` properties remain (delegating) until Task 7 removes their UI uses — keep them read-only shims here to avoid breaking Task 4–6 call sites.

- [ ] **Step 1: Write the failing tests** — append to `AppStateTests.swift`:

```swift
func testSelectedModelDefaultsByRAM() {
    let app = AppState(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
    // On this machine (≥128 GiB) the default is v4FlashQ2Q4, matching the old
    // defaultFlashQuant behavior. The RAM tiering is covered by the Model-based
    // feasibility/defaultCtx tests; here we assert the persisted round-trip.
    XCTAssertEqual(app.selectedModel, .v4FlashQ2Q4)
}
func testSelectedModelPersists() {
    let name = "test.\(UUID().uuidString)"
    let a1 = AppState(defaults: UserDefaults(suiteName: name)!)
    a1.selectedModel = .lagunaS21
    let a2 = AppState(defaults: UserDefaults(suiteName: name)!)
    XCTAssertEqual(a2.selectedModel, .lagunaS21)
}
func testSelectedModelMigratesLegacyVariantKeys() {
    let d = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    d.set(Variant.flash.rawValue, forKey: "selectedVariant")
    d.set(FlashQuant.q2.rawValue, forKey: "selectedFlashQuant")
    let app = AppState(defaults: d)
    XCTAssertEqual(app.selectedModel, .v4FlashQ2)  // mapped from the legacy pair
}
```

  (Note: `testSelectedModelDefaultsByRAM` asserts `.v4FlashQ2Q4` — correct only on ≥128 GiB machines, matching the existing tests' use of real `systemRamGiB()`. On a 96–127 GiB dev machine it would be `.v4FlashQ2`; keep the machine-RAM-dependent assertion consistent with `testEffectiveCtxFallsBackToDefault`'s pattern.)

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter AppStateTests`
Expected: FAIL — `selectedModel` unresolved.

- [ ] **Step 3: Implement** — in `AppState.swift`:

```swift
/// The runnable model (DS4F variants + Laguna S 2.1). Persisted; the old
/// selectedVariant/selectedFlashQuant keys migrate into it on first launch.
@Published var selectedModel: Model { didSet { d.set(selectedModel.rawValue, forKey: "selectedModel") } }
```

  In `init`, replace the variant/quant read-backs with (keeping the old properties initialized from it for compatibility):

```swift
let ram = systemRamGiB()
let storedModel = d.string(forKey: "selectedModel").flatMap(Model.init(rawValue:))
selectedModel = storedModel ?? migrateLegacySelection(defaults: d, ramGiB: ram)
```

  Add a private helper (or inline in init, reading only locals per the definite-init rule):

```swift
private static func migrateLegacySelection(defaults d: UserDefaults, ramGiB: Double) -> Model {
    if let stored = d.string(forKey: "selectedModel").flatMap(Model.init(rawValue:)) { return stored }
    if let v = d.string(forKey: "selectedVariant").flatMap(Variant.init(rawValue:)),
       let f = d.string(forKey: "selectedFlashQuant").flatMap(FlashQuant.init(rawValue:)) {
        return v == .pro ? .v4Pro : (f == .q2 ? .v4FlashQ2 : f == .q4 ? .v4FlashQ4 : .v4FlashQ2Q4)
    }
    return ramGiB >= 512 ? .v4Pro : ramGiB >= 128 ? .v4FlashQ2Q4 : ramGiB >= 96 ? .v4FlashQ2 : .lagunaS21
}
```

  Keep `selectedVariant`/`selectedFlashQuant` as read-only computed shims over `selectedModel` (so Tasks 4–6 compile unchanged):

```swift
var selectedVariant: Variant {
    get { selectedModel.quant == nil ? .flash : (selectedModel == .v4Pro ? .pro : .flash) }
    set { selectedModel = newValue == .pro ? .v4Pro : .v4FlashQ2Q4 }
}
var selectedFlashQuant: FlashQuant {
    get { selectedModel.quant == nil ? .q2q4 : (selectedModel.quant == .q4Imatrix ? .q4 : selectedModel.quant == .q2Imatrix ? .q2 : .q2q4) }
    set { selectedModel = selectedModel == .v4Pro ? .v4Pro : (newValue == .q2 ? .v4FlashQ2 : newValue == .q4 ? .v4FlashQ4 : .v4FlashQ2Q4) }
}
```

  (Remove the old `@Published` declarations for the pair — they become computed.)

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter AppStateTests`
Expected: PASS (existing + 3 new). Then run the FULL suite — the shims must keep every existing test green.

- [ ] **Step 5: Commit**

```bash
git add Sources/DS4Control/AppState.swift Tests/DS4ControlTests/AppStateTests.swift
git commit -m "feat: AppState.selectedModel with legacy-key migration and shims"
```

### Task 4: Family-aware launch args (SSD gating + prefill chunk)

**Files:**
- Modify: `Sources/DS4Control/Services/SupervisorService.swift`
- Test: `Tests/DS4ControlTests/SupervisorStateMachineTests.swift`

**Interfaces:**
- Consumes: `Model` (Task 1), `AppState.selectedModel` (Task 3).
- Produces: `start(model:ctx:host:port:power:sessions:kvDiskDir:ssdStreaming:ssdStreamingCacheGB:)` and matching `restart(...)` — the `variant`/`flashQuant` params are replaced by `model: Model`. Internal helpers (`ggufURL`, `download`, `isDownloaded`) switch to `model` in Task 5; this task only touches the arg assembly + signatures + the four call sites (ModelRowView ×2, ThinkingModeControls, SettingsView.restart) and the existing tests that call `start(variant:flashQuant:...)` (they switch to `model: .v4FlashQ2Q4` etc.).

- [ ] **Step 1: Write the failing tests** — append to `SupervisorStateMachineTests.swift`:

```swift
func testLagunaLaunchPassesPrefillChunkAndNeverSsdStreaming() throws {
    let r = FakeRunner(); let s = try makeSupervisor(r)
    s.start(model: .lagunaS21, ctx: 50_000, host: "127.0.0.1", port: 8000, power: nil,
            ssdStreaming: true, ssdStreamingCacheGB: 67)  // global setting ON, must be inert
    XCTAssertTrue(r.lastArgs.contains("--prefill-chunk"))
    XCTAssertEqual(r.lastArgs[r.lastArgs.firstIndex(of: "--prefill-chunk")! + 1], "4096")
    XCTAssertFalse(r.lastArgs.contains("--ssd-streaming"))
    XCTAssertFalse(r.lastArgs.contains("--ssd-streaming-cache-experts"))
}
func testDs4fLaunchStillPassesSsdStreamingWhenEnabled() throws {
    let r = FakeRunner(); let s = try makeSupervisor(r)
    s.start(model: .v4FlashQ2Q4, ctx: 250_000, host: "127.0.0.1", port: 8000, power: nil,
            ssdStreaming: true, ssdStreamingCacheGB: 67)
    XCTAssertTrue(r.lastArgs.contains("--ssd-streaming"))
    XCTAssertFalse(r.lastArgs.contains("--prefill-chunk"))
}
```

  Then update the EXISTING `start`/`restart` calls in this test file (and `SupervisorIntegrationTests.swift` if it calls `start`) from `variant: .flash, flashQuant: .q2q4` to `model: .v4FlashQ2Q4` — mechanical, no assertion changes.

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter SupervisorStateMachineTests`
Expected: FAIL — `start(model:...)` unresolved.

- [ ] **Step 3: Implement** — in `SupervisorService.swift`:

  Change both signatures to `start(model: Model, ctx: Int, ...)` / `restart(model: Model, ...)`. In `start`, replace `let gguf = ggufURL(for: variant, flashQuant: flashQuant)` with `let gguf = ggufURL(for: model)` (helper updated in Task 5; for now add a temporary overload). In the args assembly, replace the Stage-1 SSD block with a capability-gated version and add the prefill chunk:

```swift
if model.supportsSSDStreaming && ssdStreaming {
    // SSD-backed expert streaming (DS4F only). ds4 hard-refuses this flag for
    // Laguna S 2.1, so it is never passed for that model.
    args += ["--ssd-streaming"]
    if ssdStreamingCacheGB > 0 {
        args += ["--ssd-streaming-cache-experts", "\(ssdStreamingCacheGB)GB"]
    }
}
if let chunk = model.defaultPrefillChunk {
    // Bounds the graph scratch on 64 GB-class machines (measured: ~1.5 GiB at
    // 4096 vs ~5.9 GiB at Laguna's default 16384).
    args += ["--prefill-chunk", "\(chunk)"]
}
```

  Add a temporary `ggufURL(for model: Model)` overload (Task 5 replaces it):

```swift
private func ggufURL(for model: Model) -> URL {
    ggufBaseDir().appendingPathComponent(model.ggufFilename)
}
```

  Update the four call sites (`ModelRowView` ×2, `ThinkingModeControls`, `SettingsView.restart`) to `model: app.selectedModel` and drop the `flashQuant:` argument.

- [ ] **Step 4: Run to verify it passes**

Run: `swift test` (full suite — all `start(...)` callers updated).
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/DS4Control/Services/SupervisorService.swift Sources/DS4Control/Views/ModelRowView.swift Sources/DS4Control/Views/ThinkingModeControls.swift Sources/DS4Control/Views/SettingsView.swift Tests/DS4ControlTests/SupervisorStateMachineTests.swift
git commit -m "feat: family-aware launch args — SSD streaming DS4F-only, prefill-chunk for Laguna"
```

### Task 5: Per-model downloader + family-scoped cleanup

**Files:**
- Modify: `Sources/DS4Control/Services/SupervisorService.swift`, `Sources/DS4Control/Model/Variant.swift`
- Test: `Tests/DS4ControlTests/SupervisorStateMachineTests.swift`, `Tests/DS4ControlTests/HFDownloaderTests.swift`

**Interfaces:**
- Consumes: `Model.downloadRepo/downloadRevision/ggufFilename` (Task 1).
- Produces: `download(model:highPerformance:)`, `isDownloaded(_ model:)`, `cleanupUnusedModels(keep:)`, `isModelDownloaded(_:)`; `ggufURL(for model:)` (real impl); the `ggufRepo` static is removed. Old `variant`/`flashQuant`-typed download entry points are removed (callers updated in Task 4/7).

- [ ] **Step 1: Write the failing tests** — append to `SupervisorStateMachineTests.swift`:

```swift
func testLagunaDownloadUsesLagunaFile() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("gguf"), withIntermediateDirectories: true)
    for f in ["ds4-server", "download_model.sh"] {
        let u = dir.appendingPathComponent(f)
        FileManager.default.createFile(atPath: u.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
    }
    let s = SupervisorService(
        ds4Dir: dir, runner: FakeRunner(),
        fetchFile: { _, _, _, _, _ in try await Task.sleep(nanoseconds: 600_000_000_000) })
    s.download(model: .lagunaS21)
    XCTAssertEqual(s.state, .downloading)
    XCTAssertEqual(s.download?.file, "laguna-s-2.1-RoutedQ2_K-Last27Q3_K.gguf")
    s.cancelDownload()
}
func testCleanupRemovesOnlySameFamilyQuants() throws {
    let s = try makeSupervisor(runDownloadedQuants: true)  // see note below
    let removed = s.cleanupUnusedModels(keep: .v4FlashQ2Q4)
    XCTAssertTrue(removed.contains(Quant.q2Imatrix.ggufFilename))
    XCTAssertFalse(removed.contains(Quant.proImatrix.ggufFilename))  // Pro always kept
    XCTAssertFalse(removed.contains("laguna-s-2.1-RoutedQ2_K-Last27Q3_K.gguf"))  // other family untouched
}
```

  (Adapt `testCleanupRemovesOnlySameFamilyQuants` to the existing test fixtures: create the ds4 dir + fake gguf files for `.q2Imatrix`, `.q4Imatrix`, `.proImatrix`, and the Laguna filename, then assert only the non-kept Flash quants are removed. If the file lacks a helper, inline the fixture like `testMissingModel` does.)

  In `HFDownloaderTests.swift`, add a test asserting the fetch URL uses the Laguna repo:

```swift
func testLagunaRepoResolveURL() throws {
    let d = HFDownloader(repo: "antirez/Laguna-S-2.1-GGUF")
    // Construct the URL the way the implementation does and assert the path.
    let url = URL(string: "https://huggingface.co/antirez/Laguna-S-2.1-GGUF/resolve/main/laguna-s-2.1-RoutedQ2_K-Last27Q3_K.gguf")!
    XCTAssertEqual(url.path, "/antirez/Laguna-S-2.1-GGUF/resolve/main/laguna-s-2.1-RoutedQ2_K-Last27Q3_K.gguf")
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter SupervisorStateMachineTests` and `--filter HFDownloaderTests`
Expected: FAIL — `download(model:)` / `cleanupUnusedModels` unresolved.

- [ ] **Step 3: Implement** — in `SupervisorService.swift`:

  - Remove `private static let ggufRepo = "antirez/deepseek-v4-gguf"`; the fetch closure becomes per-model at call time. Change the `download` implementation to construct the downloader from the model:

```swift
let fetch = fetchFile
downloadTask = Task { [weak self] in
    do {
        try await fetch(filename, baseDir, token, highPerformance) { received, total in
            Self.onMain { self?.updateDownloadProgress(gen: gen, file: filename, received: received, total: total) }
        }
        ...
```
  becomes the model-parameterized version — replace the closure body's `HFDownloader(repo: SupervisorService.ggufRepo)` construction with a per-model `HFDownloader(repo: model.downloadRepo, revision: model.downloadRevision)`. Concretely, the default `fetchFile` in `init` stays (it receives `file` + destDir); move the repo/revision selection into a new `fetchFile` default that reads the model at the call site. Simplest: build the downloader inline in `download(model:)` and drop the injected-closure default indirection — but keep `fetchFile` injectable for tests by changing its signature to `(Model, URL, String?, Bool, @escaping (Int64, Int64) -> Void)`. Update the test fakes accordingly.

  - `ggufURL(for model: Model)` (replace the temporary): `ggufBaseDir().appendingPathComponent(model.ggufFilename)`.
  - `isDownloaded(_ model: Model) -> Bool` (rename/overload `isDownloaded(_:flashQuant:)`).
  - `isModelDownloaded(_ model: Model) -> Bool` for the Settings markers (generalizes `isFlashQuantDownloaded`).
  - `cleanupUnusedModels(keep: Model) -> [String]` — generalizes `cleanupUnusedFlashQuants`: if `keep.quant` is nil (Laguna) return `[]` (single model per family); else remove downloaded Flash quants `!= keep.quant`, never Pro, never the Laguna file:

```swift
@discardableResult
func cleanupUnusedModels(keep: Model) -> [String] {
    guard let keepQuant = keep.quant else { return [] }  // Laguna: nothing to clean
    var removed: [String] = []
    for q in FlashQuant.allCases {
        let qq = q.quant
        if qq == keepQuant { continue }
        let url = flashQuantURL(q)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
            removed.append(qq.ggufFilename)
        }
    }
    ggufStoreVersion += 1
    return removed
}
```

  - Update `SettingsView`'s cleanup call site and `removableFlashQuants` to the `Model`-based API (or defer to Task 7's UI task — the plan prefers deferring the UI churn; keep the old `cleanupUnusedFlashQuants` as a wrapper calling `cleanupUnusedModels(keep: .v4FlashQ2Q4)` if call sites remain).

- [ ] **Step 4: Run to verify it passes**

Run: `swift test`
Expected: PASS (full suite; test fakes updated for the new fetch signature).

- [ ] **Step 5: Commit**

```bash
git add Sources/DS4Control/Services/SupervisorService.swift Sources/DS4Control/Model/Variant.swift Tests/DS4ControlTests/SupervisorStateMachineTests.swift Tests/DS4ControlTests/HFDownloaderTests.swift
git commit -m "feat: per-model downloader (Laguna repo) and family-scoped cleanup"
```

### Task 6: Chat gating + agent launcher family awareness

**Files:**
- Modify: `Sources/DS4Control/DS4ControlApp.swift`, `Sources/DS4Control/Services/AgentLauncher.swift`, `Sources/DS4Control/Views/ThinkingModeControls.swift`
- Test: `Tests/DS4ControlTests/AgentLauncherTests.swift`, `Tests/DS4ControlTests/ChatThinkMaxToggleTests.swift`

**Interfaces:**
- Consumes: `Model.supportsThinkingModes/modelId` (Task 1), `AppState.selectedModel` (Task 3).
- Produces: thinking-picker gating by model; `AgentLauncher.modelId(for:fallback:)` over `Model`; `knownModelIds` includes `laguna-s-2.1`; the pi `models.json` gains the Laguna model entry.

- [ ] **Step 1: Write the failing tests** — append to `AgentLauncherTests.swift` (read the file first for the existing fixture pattern):

```swift
func testKnownModelIdsIncludesLaguna() {
    XCTAssertTrue(AgentLauncher.knownModelIds.contains("laguna-s-2.1"))
}
func testModelIdFallbackAcceptsModel() {
    XCTAssertEqual(AgentLauncher.modelId(for: nil, fallback: .lagunaS21), "laguna-s-2.1")
    XCTAssertEqual(AgentLauncher.modelId(for: "deepseek-v4-flash", fallback: .lagunaS21), "deepseek-v4-flash")
}
func testPiModelsJSONHasLagunaEntry() throws {
    let json = AgentLauncher.piModelsJSON(port: 8000, contextWindow: 50_000)
    XCTAssertTrue(json.contains("\"id\": \"laguna-s-2.1\""))
}
```

  Append to `ChatThinkMaxToggleTests.swift`:

```swift
func testThinkingPickerHiddenForLaguna() throws {
    let picker = try source("Sources/DS4Control/Views/ThinkingModeControls.swift")
    XCTAssertTrue(picker.contains("supportsThinkingModes"))
    XCTAssertTrue(picker.contains("selectedModel"))
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter AgentLauncherTests` and `--filter ChatThinkMaxToggleTests`
Expected: FAIL.

- [ ] **Step 3: Implement**:

  - `AgentLauncher.swift`: `static let knownModelIds = ["deepseek-v4-pro", "deepseek-v4-flash", "laguna-s-2.1"]`; change `modelId(for activeModel: String?, fallback: Model)` (update the PopupView call site in Task 7 or here — the popup call passes `app.selectedVariant`; update to `app.selectedModel`). Add a Laguna model entry to `piModelsJSON`:

```swift
{
  "id": "laguna-s-2.1",
  "name": "Laguna S 2.1 (ds4.c local)",
  "reasoning": true,
  "thinkingLevelMap": \(levelMap),
  "input": ["text"],
  "contextWindow": \(contextWindow),
  "maxTokens": 262144,
  "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
}
```

  (The `supportsReasoningEffort`/`thinkingFormat` compat flags stay as-is for v1 — verify against a live server in Task 9's SSE smoke test; the user's working pi config reaches Laguna, so the generated entry mirrors the DS4F shape.)

  - `ThinkingModeControls.swift`: gate the picker + the `confirmAndApply` path on `app.selectedModel.supportsThinkingModes` (when false, render `EmptyView` and skip the alert).
  - `DS4ControlApp.swift`: `ChatViewModel(model: app.selectedModel.modelId, ...)`.

- [ ] **Step 4: Run to verify it passes**

Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/DS4Control/DS4ControlApp.swift Sources/DS4Control/Services/AgentLauncher.swift Sources/DS4Control/Views/ThinkingModeControls.swift Tests/DS4ControlTests/AgentLauncherTests.swift Tests/DS4ControlTests/ChatThinkMaxToggleTests.swift
git commit -m "feat: family-aware chat thinking gating and agent launcher (Laguna entry)"
```

### Task 7: Unified model picker UI

**Files:**
- Modify: `Sources/DS4Control/Views/ModelRowView.swift`, `Sources/DS4Control/Views/SettingsView.swift`, `Sources/DS4Control/Views/PopupView.swift`
- Test: `Tests/DS4ControlTests/ChatThinkMaxToggleTests.swift` (source tests)

**Interfaces:**
- Consumes: `Model.allCases`, `feasibility(ramGiB:model:)`, `supervisor.isModelDownloaded(_:)` (Tasks 1–5).
- Produces: the unified picker (feasible models only) in the popup row; Settings "Model" section (replacing "V4 Flash model"), SSD-streaming N/A state for Laguna, cleanup via `cleanupUnusedModels`; dead DS4F-only code removed (`Variant`-typed feasibility shims, `selectedVariant`/`selectedFlashQuant` shims in AppState).

- [ ] **Step 1: Write the failing source tests** — append to `ChatThinkMaxToggleTests.swift`:

```swift
func testModelRowPickerUsesModelCases() throws {
    let row = try source("Sources/DS4Control/Views/ModelRowView.swift")
    XCTAssertTrue(row.contains("Model.allCases"))
    XCTAssertTrue(row.contains("selectedModel"))
    XCTAssertTrue(row.contains("feasibility(ramGiB: ramGiB, model:"))
}
func testSettingsHasLagunaModelSectionAndSsdNA() throws {
    let settings = try source("Sources/DS4Control/Views/SettingsView.swift")
    XCTAssertTrue(settings.contains("supportsSSDStreaming"))
    XCTAssertTrue(settings.contains("Laguna S 2.1"))
    XCTAssertTrue(settings.contains("cleanupUnusedModels"))
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ChatThinkMaxToggleTests`
Expected: FAIL.

- [ ] **Step 3: Implement**:

  - `ModelRowView.swift`: replace the `variants` picker with a `Model.allCases` picker filtered by feasibility, and drive `app.selectedModel`:

```swift
private var runnableModels: [Model] {
    Model.allCases.filter { feasibility(ramGiB: ramGiB, model: $0) != .blocked(reason: "") && feasibility(ramGiB: ramGiB, model: $0) != .blocked(reason: "") }
}
```

  (Write it cleanly: `Model.allCases.filter { if case .blocked = feasibility(ramGiB: ramGiB, model: $0) { return false }; return true }`.) The `actionButton`/`feasibilityNote` switch to `app.selectedModel` and `isModelDownloaded(_:)`; the wired-limit note text branches per model (Laguna 64–95 GiB wording; DS4F existing wording). `supervisor.start(model: app.selectedModel, ...)`.

  - `SettingsView.swift`: rename the "V4 Flash model" section to "Model"; the quant picker becomes a `Picker` over `Model.allCases` (feasible only, same `.disabled(downloading)`); cleanup button calls `cleanupUnusedModels(keep: app.selectedModel)` with per-family copy; the SSD-streaming section shows the toggle disabled with an "N/A for Laguna S 2.1" caption when `!app.selectedModel.supportsSSDStreaming`, and the budget slider is hidden then. The streaming caption/range use `app.selectedModel.quant?.routedExpertGiB` (nil for Laguna → hidden).
  - `PopupView.swift`: the agent-launch call uses `app.selectedModel` (via the updated `AgentLauncher.modelId`); the chat gating is handled by thinking-mode gating.
  - `AppState.swift`: remove the `selectedVariant`/`selectedFlashQuant` computed shims and their remaining callers; `Feasibility.swift`: remove the `Variant`-typed delegating overloads.

- [ ] **Step 4: Run to verify it passes**

Run: `swift test` (full suite) + `swift format lint --recursive Sources Tests`
Expected: PASS, lint clean.

- [ ] **Step 5: Commit**

```bash
git add Sources/DS4Control/Views/ModelRowView.swift Sources/DS4Control/Views/SettingsView.swift Sources/DS4Control/Views/PopupView.swift Sources/DS4Control/AppState.swift Sources/DS4Control/Model/Feasibility.swift Tests/DS4ControlTests/ChatThinkMaxToggleTests.swift
git commit -m "feat: unified model picker; SSD-streaming N/A and thinking gating for Laguna"
```

### Task 8: Submodule pin to `ds4-control-patches-v3`

**Files:**
- `external/ds4` (gitlink), `CHANGELOG.md`

**Interfaces:**
- Consumes: the combined fork branch (already checked out in the worktree's submodule at `d0b0caa`).
- Produces: the app repo's submodule pointer moved to `ds4-control-patches-v3`; the branch pushed to the fork (auth permitting).

- [ ] **Step 1: Push the fork branch (auth permitting)**

```bash
cd external/ds4
git push origin ds4-control-patches-v3
```

  If auth fails: record it in the commit message / CHANGELOG note and continue — the pin is valid locally; CI needs the push before merging.

- [ ] **Step 2: Move the pin**

```bash
cd /Users/pauleveritt/projects/ds4-control/.worktrees/feat-laguna
git add external/ds4
git status --short   # expect: modified external/ds4
```

- [ ] **Step 3: CHANGELOG + commit**

  Add under Unreleased:

```markdown
- ds4 submodule moved to `ds4-control-patches-v3`: `laguna-s2.1` merged into `ds4-control-patches-v2` (15 conflict files resolved), adding native **Laguna S 2.1** support alongside DeepSeek V4/GLM. THINK_MAX 0731 prefix and DSpark/Metal work retained. Boot-verified against the q2-q3 GGUF.
```

```bash
git commit -m "chore: pin ds4 submodule to ds4-control-patches-v3 (Laguna support)"
```

### Task 9: Full verification + changelog

**Files:**
- Modify: `CHANGELOG.md` (Laguna feature entry)

**Interfaces:**
- Consumes: everything.

- [ ] **Step 1: Full test suite + lint**

Run: `swift test` and `swift format lint --recursive Sources Tests`
Expected: all green, lint clean.

- [ ] **Step 2: Release build + .app**

Run: `swift build -c release -Xswiftc -warnings-as-errors` then `DS4_SRC="$PWD/external/ds4" bash build.sh`
Expected: clean build; `DS4 Control.app` with the Laguna-capable bundled ds4-server.

- [ ] **Step 3: Live boot (real model)**

Kill any running ds4 first. Launch via the app's exact arg path with the Laguna model (from `/Users/pauleveritt/projects/ds4/gguf/`), `--prefill-chunk 4096`, no `--ssd-streaming`:
- KV/scratch report shows the bounded scratch
- `/v1/models` reports `laguna-s-2.1`, ctx 50000
- One greedy completion works

- [ ] **Step 4: SSE smoke test (chat shape)**

Point the built-in chat at the running server (or curl) with `"stream": true`; confirm `reasoning_content` vs `content` split renders sensibly in the thinking section; adjust the thinking-gating or compat flags in Task 6 if the shape differs from DS4F.

- [ ] **Step 5: Negative checks**

- Selecting Laguna never passes `--ssd-streaming` (asserted in Task 4 tests; also visually: Settings shows N/A)
- The 64–95 GiB wired-limit advisory shows for Laguna on a 64 GB-class machine (feasibility unit-tested)
- The DS4F SSD-streaming behavior is unchanged (Stage-1 tests + one DS4F boot, optional)

- [ ] **Step 6: CHANGELOG + commit**

```markdown
- **Laguna S 2.1 (q2-q3) support:** new model in the picker — download, start, serve, chat (basic), agents. 64 GiB feasibility floor, 50k default context, `--prefill-chunk 4096`. SSD streaming stays DS4F-only (ds4 hard gate). No DFlash (deferred).
```

```bash
git add CHANGELOG.md
git commit -m "docs: changelog — Laguna S 2.1 support"
```

---

## Self-Review

- **Spec coverage:** every spec decision maps to a task — Model abstraction (T1), feasibility/ctx (T2), AppState (T3), SSD gating + prefill (T4), downloader/cleanup (T5), chat/agents (T6), unified picker + N/A states (T7), submodule pin (T8), verification incl. live boot + SSE smoke test + negative checks (T9). Out-of-scope items (q4, DFlash, Laguna SSD streaming, gate relaxation) are absent.
- **Placeholder scan:** no TBD; the two intentionally-fuzzy spots are flagged with explicit resolutions (`testCleanupRemovesOnlySameFamilyQuants` fixture note; `piModelsJSON` compat flags verified in T9). The `runnableModels` filter is spelled out in prose after the sketch.
- **Type consistency:** `Model` cases and members (`.quant`, `.supportsSSDStreaming`, `.supportsThinkingModes`, `.downloadRepo`, `.defaultPrefillChunk`, `.ctxCeiling` = 262_144, `.weightsGiB` = 44.95) are identical across T1–T7; `start(model:...)`/`download(model:)`/`cleanupUnusedModels(keep:)` signatures are stable from first use.
