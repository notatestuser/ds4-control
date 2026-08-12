# SSD Streaming Implementation Plan (Staged)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stage 1 — ship SSD streaming for `ds4-server` in DS4 Control, default ON with an expert-cache budget that frees ~15 GiB of resident model weights (moved to SSD), exposed as a Settings toggle + slider. Stage 2 (captured, not scheduled) — multi-model support for Laguna S 2.1.

**Architecture:** `ds4-server` already supports `--ssd-streaming` with an explicit `--ssd-streaming-cache-experts NGB` budget (measured model facts in the design spec: q2-q4 0731 has 82.7 GiB of routed expert weights; a 67 GB cache budget frees ~15.7 GiB; ds4's startup log reports the actual cache). The app changes are additive: a per-quant expert-size table on `Quant` (`Model/Variant.swift`), two persisted AppState settings, two defaulted params on `SupervisorService.start()/restart()`, and a new Settings section — all following existing patterns.

**Tech Stack:** Swift 6, SwiftPM, SwiftUI, XCTest. Backing server: vendored `ds4-server` (Metal backend).

**Design spec:** `docs/superpowers/specs/2026-08-12-ssd-streaming-design.md` (approved 2026-08-12).

## Global Constraints

- **Build/test commands need the SwiftUIMacros plugin workaround** on this machine: `xcode-select` points at CommandLineTools (no `libSwiftUIMacros.dylib`) and Xcode's license is unaccepted. Every `swift build` / `swift test` in this plan must use:

  ```bash
  export SWIFTUI_PLUGIN="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib"
  swift build -Xswiftc -Xfrontend -Xswiftc -load-plugin-library -Xswiftc -Xfrontend -Xswiftc "$SWIFTUI_PLUGIN"
  swift test  -Xswiftc -Xfrontend -Xswiftc -load-plugin-library -Xswiftc -Xfrontend -Xswiftc "$SWIFTUI_PLUGIN"
  ```

  (CI on `macos-26` needs no workaround. Permanent local fix: `sudo xcode-select -s /Applications/Xcode.app` + `sudo xcodebuild -license accept`, then plain commands work.)
- Repo root: `/Users/pauleveritt/projects/ds4-control`. Run tests from there.
- **Follow existing patterns exactly:** AppState settings are `@Published var X { didSet { d.set(X, forKey:) } }` with read-back in `init`; SupervisorService arg tests use the file-private `FakeRunner` in `SupervisorStateMachineTests.swift`; view presence is asserted via source-containment tests (see `ChatThinkMaxToggleTests.source(_:)`).
- CI runs `swift format lint --strict --recursive Sources Tests` — keep formatting clean (run `swift format lint --recursive Sources Tests` before committing; the project uses `.swift-format`).
- No code changes outside the files listed per task. No Laguna work in Stage 1.
- All test-file changes are additive; existing tests must keep passing.

---

## Stage 1 — SSD Streaming (the "no-Laguna" build)

### Task 1: Per-quant routed-expert table + default budget

**Files:**
- Modify: `Sources/DS4Control/Model/Variant.swift` (add two members to `Quant`)
- Test: `Tests/DS4ControlTests/VariantTests.swift`

**Interfaces:**
- Produces: `Quant.routedExpertGiB: Double` and `Quant.defaultStreamingCacheGB: Int` (truncating `Int(routedExpertGiB - 15)`, floor 16). Consumed by Tasks 2 and 5.

- [ ] **Step 1: Write the failing tests** — append to `VariantTests.swift`:

```swift
func testRoutedExpertGiB() {
    XCTAssertEqual(Quant.proImatrix.routedExpertGiB, 424, accuracy: 1)  // estimated: 432 − ~8 non-routed
    XCTAssertEqual(Quant.q4Imatrix.routedExpertGiB, 145, accuracy: 1)  // estimated: 153 − ~8 non-routed
    XCTAssertEqual(Quant.q2Imatrix.routedExpertGiB, 73, accuracy: 1)  // estimated: 81 − ~8 non-routed
    XCTAssertEqual(Quant.q2q4Imatrix.routedExpertGiB, 82.69, accuracy: 0.01)  // MEASURED from 0731 GGUF metadata
}
func testDefaultStreamingCacheGB() {
    // Truncating budget that leaves ~15 GiB of routed experts to stream from SSD.
    XCTAssertEqual(Quant.proImatrix.defaultStreamingCacheGB, 409)
    XCTAssertEqual(Quant.q4Imatrix.defaultStreamingCacheGB, 130)
    XCTAssertEqual(Quant.q2Imatrix.defaultStreamingCacheGB, 58)
    XCTAssertEqual(Quant.q2q4Imatrix.defaultStreamingCacheGB, 67)  // 82.69 − 15 = 67.69 → 67
}
```

  (The floor of 16 GiB in `defaultStreamingCacheGB` is defensive only — every real quant is ≥ 73 GiB — so it is not separately unit-tested.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test -Xswiftc -Xfrontend -Xswiftc -load-plugin-library -Xswiftc -Xfrontend -Xswiftc -load-plugin-library "$SWIFTUI_PLUGIN" --filter VariantTests` (with `SWIFTUI_PLUGIN` exported per Global Constraints)
Expected: FAIL — `routedExpertGiB`/`defaultStreamingCacheGB` unresolved.

- [ ] **Step 3: Implement** — in `Variant.swift`, inside `enum Quant` (after `weightsGiB`):

```swift
/// Routed-expert tensor bytes (GiB) — the weights SSD streaming can push to disk.
/// q2-q4 measured from the 0731 GGUF metadata (ffn gate/up/down expert tensors);
/// the others are estimated as total weights minus ~8 GiB non-routed
/// (attention, embeddings, shared FFN, norms).
var routedExpertGiB: Double {
    switch self {
    case .proImatrix: return 424
    case .q4Imatrix: return 145
    case .q2Imatrix: return 73
    case .q2q4Imatrix: return 82.69
    }
}

/// Default SSD-streaming expert-cache budget (GiB) for this quant: keeps all but
/// ~15 GiB of routed experts resident; the rest stream from the GGUF on demand.
/// Truncates (82.69 − 15 → 67). Floor 16 so a degenerate tiny cache can never be
/// configured accidentally.
var defaultStreamingCacheGB: Int { max(16, Int(routedExpertGiB - 15)) }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test -Xswiftc -Xfrontend -Xswiftc -load-plugin-library -Xswiftc -Xfrontend -Xswiftc "$SWIFTUI_PLUGIN" --filter VariantTests`
Expected: PASS (6 tests, existing + new).

- [ ] **Step 5: Commit**

```bash
git add Sources/DS4Control/Model/Variant.swift Tests/DS4ControlTests/VariantTests.swift
git commit -m "feat: per-quant routed-expert table for SSD streaming defaults"
```

### Task 2: AppState settings (default ON, 15 GiB-free budget)

**Files:**
- Modify: `Sources/DS4Control/AppState.swift`
- Test: `Tests/DS4ControlTests/AppStateTests.swift`

**Interfaces:**
- Consumes: `Quant.routedExpertGiB` / `Quant.defaultStreamingCacheGB` (Task 1).
- Produces: `AppState.ssdStreaming: Bool` (default `true`) and `AppState.ssdStreamingCacheGB: Int` (default = `Quant.for(selectedVariant, flashQuant: selectedFlashQuant).defaultStreamingCacheGB`). Consumed by Tasks 3–5.

- [ ] **Step 1: Write the failing tests** — append to `AppStateTests.swift`:

```swift
func testSsdStreamingDefaultsOnAndPersists() {
    let name = "test.\(UUID().uuidString)"
    let a1 = AppState(defaults: UserDefaults(suiteName: name)!)
    XCTAssertTrue(a1.ssdStreaming)  // default ON — frees ~15 GiB on fresh installs
    a1.ssdStreaming = false
    let a2 = AppState(defaults: UserDefaults(suiteName: name)!)
    XCTAssertFalse(a2.ssdStreaming)  // persisted
}
func testSsdStreamingCacheGBDefaultsToFree15BudgetAndPersists() {
    let name = "test.\(UUID().uuidString)"
    let a1 = AppState(defaults: UserDefaults(suiteName: name)!)
    XCTAssertEqual(
        a1.ssdStreamingCacheGB,
        Quant.for(a1.selectedVariant, flashQuant: a1.selectedFlashQuant).defaultStreamingCacheGB)
    a1.ssdStreamingCacheGB = 80
    let a2 = AppState(defaults: UserDefaults(suiteName: name)!)
    XCTAssertEqual(a2.ssdStreamingCacheGB, 80)  // persisted, not re-defaulted
}
```

  (The default-then-uses-machine-RAM assertion matches the existing `testEffectiveCtxFallsBackToDefault` pattern; the exact `67` for q2-q4 is asserted in Task 1.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test -Xswiftc -Xfrontend -Xswiftc -load-plugin-library -Xswiftc -Xfrontend -Xswiftc "$SWIFTUI_PLUGIN" --filter AppStateTests`
Expected: FAIL — `ssdStreaming`/`ssdStreamingCacheGB` unresolved.

- [ ] **Step 3: Implement** — in `AppState.swift`, add properties alongside the other `@Published` settings (after `kvDiskCache`):

```swift
/// SSD streaming: cache only `ssdStreamingCacheGB` of routed experts in RAM; the
/// rest stream from the GGUF on demand. Default ON with the ~15 GiB-free budget
/// for the selected quant.
@Published var ssdStreaming: Bool { didSet { d.set(ssdStreaming, forKey: "ssdStreaming") } }
@Published var ssdStreamingCacheGB: Int {
    didSet { d.set(ssdStreamingCacheGB, forKey: "ssdStreamingCacheGB") }
}
```

  In `init`, after the `selectedVariant`/`selectedFlashQuant` read-backs (so the default can key off them):

```swift
ssdStreaming = d.object(forKey: "ssdStreaming") as? Bool ?? true  // default on
let storedGB = d.object(forKey: "ssdStreamingCacheGB") as? Int
ssdStreamingCacheGB =
    storedGB ?? Quant.for(selectedVariant, flashQuant: selectedFlashQuant).defaultStreamingCacheGB
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test -Xswiftc -Xfrontend -Xswiftc -load-plugin-library -Xswiftc -Xfrontend -Xswiftc "$SWIFTUI_PLUGIN" --filter AppStateTests`
Expected: PASS (existing + 2 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/DS4Control/AppState.swift Tests/DS4ControlTests/AppStateTests.swift
git commit -m "feat: SSD streaming AppState settings, default ON with ~15 GiB-free budget"
```

### Task 3: SupervisorService launch args

**Files:**
- Modify: `Sources/DS4Control/Services/SupervisorService.swift` (`start(...)` and `restart(...)`)
- Test: `Tests/DS4ControlTests/SupervisorStateMachineTests.swift`

**Interfaces:**
- Consumes: nothing new (raw `Bool`/`Int` params from callers).
- Produces: `SupervisorService.start(variant:flashQuant:ctx:host:port:power:sessions:kvDiskDir:ssdStreaming:ssdStreamingCacheGB:)` and the matching `restart(...)` — both with `ssdStreaming: Bool = false, ssdStreamingCacheGB: Int = 0` appended as defaulted params (existing callers keep compiling). Consumed by Task 4.

- [ ] **Step 1: Write the failing tests** — append to `SupervisorStateMachineTests.swift`:

```swift
func testStartAddsSsdStreamingArgsWhenEnabled() throws {
    let r = FakeRunner(); let s = try makeSupervisor(r)
    s.start(
        variant: .flash, flashQuant: .q2q4, ctx: 250_000, host: "127.0.0.1", port: 8000,
        power: nil, ssdStreaming: true, ssdStreamingCacheGB: 67)
    XCTAssertTrue(r.lastArgs.contains("--ssd-streaming"))
    XCTAssertEqual(
        r.lastArgs[r.lastArgs.firstIndex(of: "--ssd-streaming-cache-experts")! + 1], "67GB")
}
func testStartOmitsSsdStreamingArgsByDefault() throws {
    let r = FakeRunner(); let s = try makeSupervisor(r)
    s.start(variant: .flash, flashQuant: .q2q4, ctx: 250_000, host: "127.0.0.1", port: 8000, power: nil)
    XCTAssertFalse(r.lastArgs.contains("--ssd-streaming"))
    XCTAssertFalse(r.lastArgs.contains("--ssd-streaming-cache-experts"))
}
func testStartStreamingWithoutBudgetPassesToggleOnly() throws {
    let r = FakeRunner(); let s = try makeSupervisor(r)
    s.start(
        variant: .flash, flashQuant: .q2q4, ctx: 250_000, host: "127.0.0.1", port: 8000,
        power: nil, ssdStreaming: true, ssdStreamingCacheGB: 0)
    XCTAssertTrue(r.lastArgs.contains("--ssd-streaming"))
    XCTAssertFalse(r.lastArgs.contains("--ssd-streaming-cache-experts"))
}
func testRestartRelaunchCarriesSsdStreamingArgs() throws {
    let r = FakeRunner(); let s = try makeSupervisor(r)
    s.start(variant: .flash, flashQuant: .q2q4, ctx: 250_000, host: "127.0.0.1", port: 8000, power: nil)
    r.emit("ds4-server: listening on http://127.0.0.1:8000")
    s.restart(
        variant: .flash, flashQuant: .q2q4, ctx: 393_216, host: "127.0.0.1", port: 8000,
        power: nil, ssdStreaming: true, ssdStreamingCacheGB: 67)
    XCTAssertTrue(r.lastArgs.contains("--ssd-streaming"))
    XCTAssertEqual(
        r.lastArgs[r.lastArgs.firstIndex(of: "--ssd-streaming-cache-experts")! + 1], "67GB")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test -Xswiftc -Xfrontend -Xswiftc -load-plugin-library -Xswiftc -Xfrontend -Xswiftc "$SWIFTUI_PLUGIN" --filter SupervisorStateMachineTests`
Expected: FAIL — `ssdStreaming`/`ssdStreamingCacheGB` are extra arguments.

- [ ] **Step 3: Implement** — in `SupervisorService.swift`, extend both signatures:

```swift
func start(
    variant: Variant,
    flashQuant: FlashQuant,
    ctx: Int,
    host: String,
    port: Int,
    power: Int?,
    sessions: Int = 1,
    kvDiskDir: URL? = nil,
    ssdStreaming: Bool = false,
    ssdStreamingCacheGB: Int = 0
)
```

  and the identical param list on `restart(...)`. In `start`, right after the `--metal` line in the args assembly (before the `if let power` block):

```swift
if ssdStreaming {
    // SSD-backed expert streaming: only `ssdStreamingCacheGB` of routed experts
    // stay resident; the rest load from the GGUF on cache miss. 0 omits the
    // budget so ds4 picks its automatic cache.
    args += ["--ssd-streaming"]
    if ssdStreamingCacheGB > 0 {
        args += ["--ssd-streaming-cache-experts", "\(ssdStreamingCacheGB)GB"]
    }
}
```

  In `restart`, forward the two values into the `start(...)` call inside the `relaunch` closure.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test -Xswiftc -Xfrontend -Xswiftc -load-plugin-library -Xswiftc -Xfrontend -Xswiftc "$SWIFTUI_PLUGIN" --filter SupervisorStateMachineTests`
Expected: PASS (existing + 4 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/DS4Control/Services/SupervisorService.swift Tests/DS4ControlTests/SupervisorStateMachineTests.swift
git commit -m "feat: pass --ssd-streaming and expert-cache budget to ds4-server"
```

### Task 4: Thread the setting through the four call sites

**Files:**
- Modify: `Sources/DS4Control/Views/ModelRowView.swift` (two `supervisor.start(...)` calls), `Sources/DS4Control/Views/ThinkingModeControls.swift` (one `supervisor.restart(...)` call), `Sources/DS4Control/Views/SettingsView.swift` (the `restart()` helper)
- Test: `Tests/DS4ControlTests/ChatThinkMaxToggleTests.swift` (source-containment additions)

**Interfaces:**
- Consumes: `app.ssdStreaming`, `app.ssdStreamingCacheGB` (Task 2) and the Task 3 signatures.
- Produces: all launch/restart paths carrying the setting.

- [ ] **Step 1: Write the failing source tests** — append to `ChatThinkMaxToggleTests.swift` (the class already has the private `source(_:)` helper):

```swift
func testModelRowStartThreadsSsdStreamingSetting() throws {
    let modelRow = try source("Sources/DS4Control/Views/ModelRowView.swift")
    XCTAssertEqual(
        modelRow.components(separatedBy: "supervisor.start(").count - 1, 2,
        "both start call sites must pass the setting")
    // Both call sites use identical trailing args; assert the pattern appears twice.
    let pattern = "ssdStreaming: app.ssdStreaming, ssdStreamingCacheGB: app.ssdStreamingCacheGB"
    XCTAssertEqual(modelRow.components(separatedBy: pattern).count - 1, 2)
}
func testRestartCallSitesThreadSsdStreamingSetting() throws {
    let thinking = try source("Sources/DS4Control/Views/ThinkingModeControls.swift")
    let settings = try source("Sources/DS4Control/Views/SettingsView.swift")
    let pattern = "ssdStreaming: app.ssdStreaming, ssdStreamingCacheGB: app.ssdStreamingCacheGB"
    XCTAssertTrue(thinking.contains(pattern))
    XCTAssertTrue(settings.contains(pattern))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test -Xswiftc -Xfrontend -Xswiftc -load-plugin-library -Xswiftc -Xfrontend -Xswiftc "$SWIFTUI_PLUGIN" --filter ChatThinkMaxToggleTests`
Expected: FAIL — pattern not found.

- [ ] **Step 3: Implement** — at each call site, after the existing `kvDiskDir:` argument, add:

```swift
ssdStreaming: app.ssdStreaming,
ssdStreamingCacheGB: app.ssdStreamingCacheGB,
```

  In `ModelRowView.swift` both `supervisor.start(...)` calls get it (they are inside the `.error` retry branch and the `default` Start branch). In `ThinkingModeControls.confirmAndApply` and `SettingsView.restart()` the `supervisor.restart(...)` calls get it.

- [ ] **Step 4: Verify** — run the full test suite (build + tests with the plugin flag), expected all green; run `swift format lint --recursive Sources Tests` to confirm no lint drift.

- [ ] **Step 5: Commit**

```bash
git add Sources/DS4Control/Views/ModelRowView.swift Sources/DS4Control/Views/ThinkingModeControls.swift Sources/DS4Control/Views/SettingsView.swift Tests/DS4ControlTests/ChatThinkMaxToggleTests.swift
git commit -m "feat: thread SSD streaming setting through all start/restart call sites"
```

### Task 5: Settings UI section

**Files:**
- Modify: `Sources/DS4Control/Views/SettingsView.swift`
- Test: `Tests/DS4ControlTests/ChatThinkMaxToggleTests.swift`

**Interfaces:**
- Consumes: `AppState.ssdStreaming`, `AppState.ssdStreamingCacheGB` (Task 2), `Quant.routedExpertGiB` + existing `Quant.for(_:flashQuant:)` (Task 1).
- Produces: the "SSD streaming" Settings section (toggle + budget slider + freed-RAM caption).

- [ ] **Step 1: Write the failing source test** — append to `ChatThinkMaxToggleTests.swift`:

```swift
func testSettingsHasSsdStreamingSection() throws {
    let settings = try source("Sources/DS4Control/Views/SettingsView.swift")
    XCTAssertTrue(settings.contains(#""Stream expert weights from SSD""#))
    XCTAssertTrue(settings.contains(#"Text("SSD streaming")"#))
    XCTAssertTrue(settings.contains("ssdStreamingCacheGB"))
    XCTAssertTrue(settings.contains("routedExpertGiB"))
    // Caption shows the freed amount for the selected quant.
    XCTAssertTrue(settings.contains("frees ~"))
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test -Xswiftc -Xfrontend -Xswiftc -load-plugin-library -Xswiftc -Xfrontend -Xswiftc "$SWIFTUI_PLUGIN" --filter ChatThinkMaxToggleTests`
Expected: FAIL — strings not found.

- [ ] **Step 3: Implement** — in `SettingsView.swift`:

  Add computed helpers near `sessionsBinding`:

```swift
private var streamingCacheBinding: Binding<Double> {
    Binding(get: { Double(app.ssdStreamingCacheGB) }, set: { app.ssdStreamingCacheGB = Int($0.rounded()) })
}
private var streamingCacheMaxGiB: Int {
    max(17, Int(Quant.for(app.selectedVariant, flashQuant: app.selectedFlashQuant).routedExpertGiB) - 1)
}
private var streamingCaption: String {
    let q = Quant.for(app.selectedVariant, flashQuant: app.selectedFlashQuant)
    let gb = app.ssdStreamingCacheGB
    let freed = Int(q.routedExpertGiB - Double(gb))  // truncates: 82.69 − 67 → ~15 GiB
    return
        "Expert cache \(gb) GiB — frees ~\(freed) GiB of RAM from model weights. "
        + "Decode can be slower when the SSD must refill the cache."
}
```

  Insert a new section between the `Server` section and the `Apply & Restart Server` section:

```swift
Section {
    Toggle("Stream expert weights from SSD", isOn: $app.ssdStreaming)
    if app.ssdStreaming {
        LabeledContent {
            HStack(spacing: 10) {
                Slider(value: streamingCacheBinding, in: 16...Double(streamingCacheMaxGiB), step: 1)
                Text("\(app.ssdStreamingCacheGB)")
                    .monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }
            .frame(width: 230)
        } label: {
            Text("Expert cache")
        }
        Text(streamingCaption)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
} header: {
    Text("SSD streaming")
} footer: {
    Text(
        "Keeps only part of the routed expert weights in RAM and streams the rest "
            + "from disk on demand, freeing memory for other apps. "
            + "Applies on next server start or restart.")
}
```

  (Note: the caption truncates the freed amount — `~15 GiB` for the 67 GB default — matching the default-budget formula, a deliberate deviation from the spec's rounded sketch.)

- [ ] **Step 4: Verify** — full test suite green; `swift format lint --recursive Sources Tests` clean.

- [ ] **Step 5: Commit**

```bash
git add Sources/DS4Control/Views/SettingsView.swift Tests/DS4ControlTests/ChatThinkMaxToggleTests.swift
git commit -m "feat: SSD streaming settings UI (toggle + expert-cache budget slider)"
```

### Task 6: Full build, tests, .app, and real-model verification

**Files:**
- Modify: `CHANGELOG.md` (add an entry in the existing format)

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Full test suite**

Run (from repo root, with `SWIFTUI_PLUGIN` exported):
`swift test -Xswiftc -Xfrontend -Xswiftc -load-plugin-library -Xswiftc -Xfrontend -Xswiftc "$SWIFTUI_PLUGIN"`
Expected: all tests pass.

- [ ] **Step 2: Release build**

Run: `swift build -c release -Xswiftc -Xfrontend -Xswiftc -load-plugin-library -Xswiftc -Xfrontend -Xswiftc "$SWIFTUI_PLUGIN" -Xswiftc -warnings-as-errors`
Expected: builds clean (CI parity).

- [ ] **Step 3: Build the .app**

Run (same plugin flag; `build.sh`'s own `swift build` line must be patched in a gitignored copy as was done for the initial bundle, or use the temporary wrapper at `.build/build-app.sh` from earlier — re-create it if missing by copying `build.sh` and adding the `-Xswiftc -Xfrontend -Xswiftc -load-plugin-library ...` flags to its `swift build -c release` line):
`DS4_SRC="$PWD/external/ds4" bash .build/build-app.sh`
Expected: `DS4 Control.app` builds, signed ad-hoc, `ds4-server` bundled.

- [ ] **Step 4: Real-model launch (manual, heavy — optional but recommended)**

Stop any running ds4-server first (`pkill -f ds4-server`). Launch with the exact args the app will pass for the default settings (q2-q4, 1M ctx, streaming 67 GB):

```bash
"$PWD/external/ds4/ds4-server" \
  -m "/Users/pauleveritt/Library/Application Support/DS4 Control/gguf/DeepSeek-V4-Flash-Layers37-42Q4KExperts-OtherExpertLayersIQ2XXSGateUp-Q2KDown-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-fixed-0731.gguf" \
  --ctx 1000000 --host 127.0.0.1 --port 8000 --metal \
  --ssd-streaming --ssd-streaming-cache-experts 67GB \
  --kv-disk-dir "$HOME/Library/Application Support/DS4 Control/kv" --kv-disk-space-mb 16384
```

Watch stderr for the startup cache report (grep `streaming expert cache`): it prints the actual expert budget and target GiB — the authoritative freed-amount signal. Then `ps -o rss= -p <pid>` and compare with a same-args-without-streaming launch if you want the empirical delta. Kill the server when done. (Loading the 91 GiB model takes minutes; do the comparison only if you have time for two loads.)

- [ ] **Step 5: CHANGELOG**

Add an entry under the top (unreleased) section, following the existing bullet style:
`- SSD streaming (default on): keeps ~15 GiB less of the model resident by caching only part of the routed experts; budget slider in Settings.`

- [ ] **Step 6: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: changelog — SSD streaming"
```

---

## Stage 2 (captured, NOT scheduled): Laguna S 2.1 support

The user explicitly wants the no-Laguna build first; everything below is a scoped capture of the discussion for a future plan. **Not tasks to execute now.**

**Goal (future):** let the app download and serve either DS4F (Pro/Flash) or Laguna S 2.1, with switching via the existing restart flow.

### Requirements capture

1. **Fork/submodule first (critical path).** The pinned submodule commit (`ebacae9`, `ds4-control-patches-v2`) predates Laguna. `laguna-s2.1` is a separate fork branch declaring a third family (`DS4_MODEL_FAMILY_LAGUNA`, 48 layers) in the same runtime-dispatched `ds4.c` (`DS4_MODEL_FAMILY`/`DS4_MODEL_VARIANT` are read from the GGUF shape at runtime — one server binary serves both, no separate build). The THINK_MAX patch must be rebased/merged onto a Laguna-capable commit, then the pin bumps and CI/release re-verified. `build.sh` needs no change (it bundles whatever the submodule has).
2. **Downloads (DFlash explicitly SKIPPED per user).** DS4F repo: `antirez/deepseek-v4-gguf`. Laguna: `laguna-q4` → `poolside/Laguna-S-2.1-GGUF` / `laguna-s-2.1-Q4_K_M.gguf` (63.56 GiB, needs the fork's pinned `HF_REVISION` — the app's `HFDownloader` already supports `revision:`); `laguna-q2-q3` → `antirez/Laguna-S-2.1-GGUF` / `laguna-s-2.1-RoutedQ2_K-Last27Q3_K.gguf` (44.95 GiB, 64 GB class). Skip `laguna-dflash` (`--dflash` speculative decoding) entirely. `SupervisorService.ggufRepo` becomes per-model repo+revision; progress totals need correct per-model `weightsGiB`.
3. **Model table.** `Variant`/`FlashQuant` generalize into a model-family × quant structure: per-family `modelId`, layers (Laguna 48), `kvBytesPerToken`, `ctxCeiling` (Laguna ≠ 1M; likely far smaller — verify model card), quants, GGUF names, repo+revision, `routedExpertGiB` (below).
4. **KV/ctx math must be re-measured.** `kvBytesPerToken = layers × 391` was measured for DS4F Flash only (via `scripts/flash-mem-harness.sh`); Laguna's attention (SWA layers) differs and needs its own harness run before `defaultCtx`/RAM budgets can be trusted.
5. **Reasoning/thinking semantics.** The chat's `reasoning_content` section, Think-Max tiers (393,216 floor, `THINK_MAX` env), and the agent launcher's Max-Think prompt are DS4-specific. Laguna advertises native interleaved reasoning — verify SSE shape and prompts against a real server before reusing them.
6. **Feasibility tier for true 64 GB class.** The app currently blocks <96 GiB. Laguna q2-q3 (44.95 GiB weights) targets 64 GB laptops: new tier + the existing wired-limit advisory math (with the 8 GiB OS reserve, weights + modest KV ≈ 55–57 GiB — tight but feasible).
7. **SSD-streaming table.** Add measured `routedExpertGiB` for Laguna quants. q2-q3 is a *mixed* routed quant (Q2_K, last 27 layers Q3_K) — the same "boosted layers can't use the single-size-class expert cache" caveat as DS4F q2-q4; the Settings freed-RAM caption follows.
8. **Chat model identity.** `ChatViewModel(model: app.selectedVariant.modelId, ...)` captures the id at launch; multi-model switching needs it bound to the running server (the `/v1/models` `loadedModelName` path already does this for adopted servers).
9. **Shared KV cache — NOT a blocker.** On-disk KV entries are namespaced by `model_id` + `quant_bits` (`ds4_kvstore.c` rejects mismatches), so DS4F/Laguna never replay each other's prefixes in the shared `App Support/DS4 Control/kv` dir; the only shared effect is the 16 GiB `--kv-disk-space-mb` budget (mutual eviction, harmless). Optional clean split: per-family `kv/<family>` subdirs. No custom `$HOME` needed for the server.
10. **Cleanup/migration generalization.** `cleanupUnusedFlashQuants` and the pre-0731 legacy-gguf banner are DS4F-shaped; new family files must be excluded and the loops generalized.
11. **Tests.** Feasibility/ctx math for the new tier, downloader tests for the second repo+revision, a Laguna KV harness, and the existing `VariantTests`/`AppStateTests` extended for the family table.

---

## Self-Review

- **Spec coverage:** every design-spec decision maps to a task — per-quant table (T1), AppState defaults/persistence (T2), arg construction incl. the 0-budget edge (T3), all four call sites (T4), Settings UI with freed-RAM caption (T5), full verification + changelog (T6). Out-of-scope items (feasibility relaxation, cold/preload knobs, per-quant persisted budgets) are deliberately absent. Laguna points are fully captured in Stage 2 with DFlash excluded.
- **Placeholder scan:** no TBD/TODO; every step has concrete code or commands. The one "re-create if missing" reference (`.build/build-app.sh`) names the exact recipe to rebuild it.
- **Type consistency:** `routedExpertGiB` (T1) is consumed by T2 (via `Quant.for`) and T5; `ssdStreaming`/`ssdStreamingCacheGB` names are identical across T2–T5; Task 3 signatures use exactly `ssdStreaming: Bool = false, ssdStreamingCacheGB: Int = 0`; test values (67GB, 67, 409/130/58/67) match the truncating formula throughout.
