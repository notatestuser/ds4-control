# DeepSeek V4.1 Flash Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add DeepSeek V4.1 Flash (Metal, Q2/Q4 GGUFs from `antirez/deepseek-v4.1-flash-gguf`) as a second Flash variant alongside V4 Flash 0731, with an exact Swift mirror of ds4@bd66c40's V4.1 memory accounting, native two-part Q4 download+join, and variant-aware launch/thinking behavior.

**Architecture:** Bump `external/ds4` from `c35cf38` to `bd66c4020` (199 commits; verified: all 0731/Pro shapes, memory formulas, and server ids are byte-identical). Add `Variant.flash41` + `Flash41Quant` + a `QuantSelection` value that replaces the `(variant, flashQuant)` pair everywhere. V4.1 gets a dedicated feasibility path mirroring `ds41_graph_bytes`/`ds41_memory_admit_for_host`, auto `--ssd-streaming`, forced `--power 100`, default ctx 32768, ceiling 1,048,576, model id `deepseek-v4.1-flash`. Downloads stay native Swift: per-quant HF repo, per-part resume, SHA-256 verification, in-place join.

**Tech Stack:** Swift 6.3 / SwiftUI, swift-testing (XCTest-style tests in `Tests/DS4ControlTests`), `swift format` lint, ds4 C submodule, CI on macos-26.

**Execution:** Inline execution on branch `v41-flash` (will become a PR), per `superpowers:executing-plans`.

**Key upstream facts (verified from ds4@bd66c4020):**
- Repo `antirez/deepseek-v4.1-flash-gguf`; Q2 `DeepSeek-V4.1-Flash-Q2.gguf` = 365,713,686,528 B, sha256 `1ce6a8f8806205c13330d7ca287bd198331dc5ca35ccc5d8a9a92a188a6f6f42`; Q4 = two parts `…Q4.gguf.part1` 480,000,000,000 B (sha `6442b1f9224079662c02003c0ef9ef6be6e2aff509510f681dab9e6cc41df246`) + `…Q4.gguf.part2` 38,596,067,328 B (sha `7c3e10646c918eeaffbc39305a75ec96117450262c61454ff194cef00d7617f0`), joined 518,596,067,328 B (sha `a5e2e2c3ada4b2e98d9f9e4b50f6d9c2a12c2c96f5da165c07e13aff9264984e`).
- Disk-only Engram tables = (384,006,168 + 384,016,682) rows × 264 B = **202,778,032,400 B**. Resident main weights: Q2 = 162,935,654,128 B (151.75 GiB), Q4 = 315,818,034,928 B (294.12 GiB).
- Arch `deepseek41`; `/v1/models` id `deepseek-v4.1-flash`; max ctx 1,048,576; `--power 100` required; `--ssd-streaming` explicit; think-max needs no ctx floor (numeric effort 1–100; chat still accepts `reasoning_effort` strings); no DSpark/TP-in-app; `--kv-disk-dir` is family-agnostic (usable).
- Source regions for the mirror: `ds4.c` @bd66c40 — prefill cap 39096-39100, carry cap 39107-39120, `DS41_SCRATCH` 39122-39150, `ds41_graph_bytes` 39223-39254, `ds41_graph_memory` 39256-39272, admission `ds41_memory_admit_for_host` 65460-65495, `weights_streaming_non_routed_bytes` 7660-7678; `ds4_gpu_dsv41_indexer_packed_bytes` in `ds4_gpu.h`/`ds4_metal.m`; `gguf-tools/deepseek41_quantize.py` for tensor inventory.

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `external/ds4` (gitlink) | bump | pin `bd66c402070042bf0a79ad6ece8242de4c93680c` |
| `Sources/DS4Control/Model/Variant.swift` | modify | `Variant.flash41`, `Flash41Quant`, `Quant` q41 cases + parts/repo/sha, `QuantSelection` |
| `Sources/DS4Control/Model/Feasibility.swift` | modify | `ds41GraphBytes`, V4.1 fixed/streaming wired, selection-based APIs, V4.1 floors/defaults |
| `Sources/DS4Control/AppState.swift` | modify | `selectedFlash41Quant`, `quantSelection`, defaults, variant-aware think gate |
| `Sources/DS4Control/Services/SupervisorService.swift` | modify | selection APIs, V4.1 args (`--power 100`, `--ssd-streaming`), multi-part download, cleanup |
| `Sources/DS4Control/Services/GGUFJoiner.swift` | create | streaming SHA-256, part verify, resumable in-place join |
| `Sources/DS4Control/Services/DownloadProbe.swift` | modify | per-quant aggregate progress/resume helpers |
| `Sources/DS4Control/Services/HFDownloader.swift` | modify | repo parameter on `download` + self-test filename fix |
| `Sources/DS4Control/Services/AgentLauncher.swift` | modify | `deepseek-v4.1-flash` id + pi model entry |
| `Sources/DS4Control/Views/ModelRowView.swift` | modify | three-variant picker, selection plumbing |
| `Sources/DS4Control/Views/SettingsView.swift` | modify | V4.1 quant section + cleanup, ctx/thinking hint variants |
| `Sources/DS4Control/Views/ThinkingModeControls.swift`, `WiredLimitHelpView.swift` | modify | selection signature, variant-aware Max gate |
| `Sources/DS4Control/DS4ControlApp.swift` | modify | resume call site |
| `scripts/flash41-mem-harness.sh` | create | V4.1 resident-memory harness |
| `README.md`, `CHANGELOG.md`, `AGENTS.md`, `CLAUDE.md` | modify | tiers, pin, derivation notes |
| `Tests/DS4ControlTests/*` | modify/add | see tasks |

---

### Task 1: Bump ds4 submodule to bd66c40

**Files:** `external/ds4` (gitlink), `patches/ds4-think-max.patch` (verify only)

- [ ] **Step 1: Restore the patch-dirtied submodule file, then fetch + checkout the V4.1 commit**

The working tree currently has `ds4.c` modified by the build-time patch. Restore it first (the patch is re-applied by script), then checkout:

```bash
git -C external/ds4 checkout -- ds4.c
git -C external/ds4 fetch origin main
git -C external/ds4 checkout bd66c402070042bf0a79ad6ece8242de4c93680c
git -C external/ds4 rev-parse HEAD
```
Expected: `bd66c402070042bf0a79ad6ece8242de4c93680c`

- [ ] **Step 2: Re-apply and sanity-check the Think-Max patch**

```bash
bash scripts/apply-ds4-patches.sh
git -C external/ds4 diff --stat -- ds4.c
git -C external/ds4 diff -- ds4.c | grep -c 'Absolute maximum'
```
Expected: script exits 0 (applies on fresh checkout; context verified identical upstream), diff touches only the `DS4_REASONING_EFFORT_MAX_PREFIX` region, grep count ≥ 1.

- [ ] **Step 3: Build ds4-server at the new pin**

```bash
make -C external/ds4 -j ds4-server
```
Expected: builds clean.

- [ ] **Step 4: Commit the bump**

```bash
git add external/ds4
git commit -m "deps: bump ds4 to bd66c40 (V4.1 Flash support)"
```

---

### Task 2: Model layer — Variant, Flash41Quant, Quant, QuantSelection

**Files:**
- Modify: `Sources/DS4Control/Model/Variant.swift`
- Modify: `Sources/DS4Control/AppState.swift:48-108,112-130`
- Test: `Tests/DS4ControlTests/VariantTests.swift`, `Tests/DS4ControlTests/AppStateTests.swift`

- [ ] **Step 1: Write the failing tests** (see repository plan; assertions cover flash41 identity, quant mapping, byte constants, Q4 parts, AppState defaults and no auto-migration of stored 0731 selections)

- [ ] **Step 2: Run tests to verify they fail** — `swift test --filter VariantTests 2>&1 | tail -5` → compile FAIL.

- [ ] **Step 3: Implement `Variant.swift`** — add `Variant.flash41` (modelId `deepseek-v4.1-flash`, kv dir `kv-flash-41`, layers 40, ceiling 1,048,576), `Quant` cases `q41Q2/q41Q4` with `repo`, `sha256`, `residentMainBytes`, `downloadParts: [QuantPart]`, `Flash41Quant` (q2/q4 + labels), `QuantSelection` (pro/flash/flash41).

- [ ] **Step 4: Implement `AppState` changes** — `selectedFlash41Quant` key, `quantSelection`, default variant `pro ≥512 / flash41 ≥128 / flash <128`, `effectiveCtx` via selection, variant-aware think gate calls.

- [ ] **Step 5: Run tests** — `swift test --filter 'VariantTests|AppStateTests'` → PASS.

- [ ] **Step 6: Commit** `feat: add V4.1 Flash variant, quants, and selection model`

---

### Task 3: Feasibility — ds41 mirror, floors, defaults

**Files:**
- Modify: `Sources/DS4Control/Model/Feasibility.swift`
- Test: `Tests/DS4ControlTests/FeasibilityTests.swift`

- [ ] **Step 1: Extract exact V4.1 accounting from the pinned source** — `ds4.c:39096-39150` (prefill/carry caps, `DS41_SCRATCH`), `39223-39272` (`ds41_graph_bytes`/`ds41_graph_memory`), `65460-65495` (admission fixed/budget), `weights_streaming_non_routed_bytes` (`7660`), `ds4_gpu_dsv41_indexer_packed_bytes` (`ds4_gpu.h`/`ds4_metal.m`), and compute the non-routed constant from `gguf-tools/deepseek41_quantize.py` + validated metadata (`ds4.c:6377-6457`).

- [ ] **Step 2: Build a throwaway C verifier** — `/tmp/ds41_calc.c` verbatim `ds41_graph_bytes` + constants + `main` printing ctx ∈ {4096, 32768, 131072, 393216, 1048576}; `cc -O2 -o /tmp/ds41_calc /tmp/ds41_calc.c && /tmp/ds41_calc`; record literals; delete the temp files.

- [ ] **Step 3: Implement the V4.1 path** — `thinkMaxNeedsCtxFloor(variant:)`, `ds41GraphBytes(ctx:)`, `v41FixedWiredMB(selection:ctx:sessions:streaming:)`, `flash41UsesSSDStreaming(ramGiB:selection:ctx:sessions:)`, `flash41QuantFits`, `defaultFlash41Quant`; change `defaultCtx(ramGiB:selection:)` (flash41 default 32,768), `requiredWiredMB(ramGiB:selection:ctx:sessions:)`, `feasibility(...)` with the ≥128 GiB V4.1 floor; `metalShape(for:)` precondition-fails for `.flash41`.

- [ ] **Step 4: Add pinned tests** — ds41 graph literals from Step 2, floor/streaming matrix (128 GiB Q2 streaming, 512 resident, 256 Q4 streaming), fixed wired = resident + graphs×sessions + 2 GiB, defaults; existing 0731/Pro literals must stay identical.

- [ ] **Step 5: Run tests** — `swift test --filter FeasibilityTests` → PASS.

- [ ] **Step 6: Commit** `feat: mirror V4.1 Flash Metal memory accounting in Feasibility`

---

### Task 4: Server launch — selection APIs, `--power 100`, `--ssd-streaming`

**Files:**
- Modify: `Sources/DS4Control/Services/SupervisorService.swift`, `Sources/DS4Control/DS4ControlApp.swift`
- Test: `Tests/DS4ControlTests/SupervisorStateMachineTests.swift`, `SupervisorIntegrationTests.swift`, `DownloadRaceTests.swift`

- [ ] **Step 1: Refactor SupervisorService to `QuantSelection`** — `WiredLimitGate` type, `start/restart/download/retryDownload/resumeInFlightDownloadIfAny/isDownloaded`, `ggufURL(for selection:)`.

- [ ] **Step 2: V4.1 launch args** — `.flash41` forces `--power 100` and passes `--ssd-streaming` when `flash41UsesSSDStreaming(...)`; legacy path unchanged.

- [ ] **Step 3: Update tests mechanically** — `rg -n 'variant: \.flash, flashQuant:|variant: \.pro, flashQuant:|flashQuant:' Tests Sources`; add a state-machine test asserting forced power/streaming args and the `deepseek-v4.1-flash` id.

- [ ] **Step 4: Run tests** — `swift test --filter 'Supervisor|DownloadRace'` → PASS.

- [ ] **Step 5: Commit** `feat: launch V4.1 Flash with forced power 100 and auto SSD streaming`

---

### Task 5: Native two-part Q4 download, SHA-256, and join

**Files:**
- Create: `Sources/DS4Control/Services/GGUFJoiner.swift`
- Modify: `Sources/DS4Control/Services/SupervisorService.swift:556-736`, `Sources/DS4Control/Services/HFDownloader.swift:145-226,284-319`
- Test: `Tests/DS4ControlTests/GGUFJoinerTests.swift` (new), `DownloadRaceTests.swift`

- [ ] **Step 1: Write failing joiner + downloader tests** — join appends + verifies sha + deletes part2; interrupted assembly resumes; checksum mismatch throws and removes the assembled file while keeping parts.

- [ ] **Step 2: Implement `GGUFJoiner.swift`** — `sha256(of:)` streaming (CryptoKit, 16 MiB blocks), `verify(url:expectedBytes:expectedSHA256:)`, `join(part1:part2:into:expectedBytes:expectedSHA256:freeSpaceRequired:)` with `.assembling` resume, free-space check, in-place append, fsync, verify, rename.

- [ ] **Step 3: Multi-part orchestration in `SupervisorService.download`** — injected fetch gains `repo`; sequential part downloads with aggregate progress; per-part SHA verification (delete the offending part on mismatch); join (free space = part2 + 1 GiB); final SHA verify; cancel/resume/cleanup cover all parts and `.assembling`.

- [ ] **Step 4: Fix the self-test filename** — `HFDownloader.runSelfTestIfRequested` uses the 0813 GA Pro name.

- [ ] **Step 5: Run tests** — `swift test --filter 'GGUFJoiner|DownloadRace|Supervisor'` → PASS.

- [ ] **Step 6: Commit** `feat: native two-part V4.1 Q4 download with SHA-256 and resumable join`

---

### Task 6: Download progress/resume helpers

**Files:** `Sources/DS4Control/Services/DownloadProbe.swift`, `Tests/DS4ControlTests/DownloadRaceTests.swift`

- [ ] **Step 1: Add per-quant aggregation** — `downloadedBytes(ggufDir:quant:)`, `hasPartialDownload(ggufDir:quant:)`.
- [ ] **Step 2: Tests + run** — `swift test --filter DownloadRace` → PASS.
- [ ] **Step 3: Commit** `feat: aggregate multi-part download progress`

---

### Task 7: UI — variant picker, Settings, thinking gates

**Files:**
- Modify: `Sources/DS4Control/Views/ModelRowView.swift`, `Views/SettingsView.swift`, `Views/ThinkingModeControls.swift`, `Views/WiredLimitHelpView.swift`
- Test: `Tests/DS4ControlTests/GUIHostOptionSourceTests.swift` + source tests as needed

- [ ] **Step 1: `ModelRowView`** — variants list `[.pro, .flash41, .flash]` (≥512), `[.flash41, .flash]` (≥128), `[.flash]` (<128); selection plumbing.
- [ ] **Step 2: `SettingsView`** — keep 0731 section; add V4.1 section (quant picker, downloaded markers, cleanup, streaming/power/Engram footer); ctx hint for 32,768 default; Max-Think floor text only when `thinkMaxNeedsCtxFloor`.
- [ ] **Step 3: Thinking controls** — `ThinkingModeControls` uses the variant-aware gate; `WiredLimitHelpView` takes `selection:`.
- [ ] **Step 4: Build + source tests** — `swift build && swift test --filter 'GUIHostOption|SourceTests'` → PASS.
- [ ] **Step 5: Commit** `feat: V4.1 Flash settings and variant UI`

---

### Task 8: Agent launcher + model ids

**Files:** `Sources/DS4Control/Services/AgentLauncher.swift`, `Tests/DS4ControlTests/AgentLauncherTests.swift`

- [ ] **Step 1: Add the id and pi entry** — `deepseek-v4.1-flash` in `knownModelIds`; third `piModelsJSON` model (`maxTokens: 1048576`).
- [ ] **Step 2: Update tests + run** — `swift test --filter AgentLauncher` → PASS.
- [ ] **Step 3: Commit** `feat: expose deepseek-v4.1-flash to coding agents`

---

### Task 9: V4.1 memory harness

**Files:** Create `scripts/flash41-mem-harness.sh`; modify `Tests/DS4ControlTests/MemoryHarnessSourceTests.swift`

- [ ] **Step 1: Clone the 0731 harness** with `DeepSeek-V4.1-Flash-Q2.gguf`, `--ssd-streaming --power 100`, model id `deepseek-v4.1-flash`, `LIMIT_GIB=${DS41_LIMIT_GIB:-128}`, default ctxs `32768 131072`, and memory-report parsing.
- [ ] **Step 2: Source-level test** — assert GGUF path, `--ssd-streaming`, 128 GiB gate; `swift test --filter MemoryHarnessSource` → PASS.
- [ ] **Step 3: Commit** `chore: add V4.1 Flash resident-memory harness`

---

### Task 10: Docs

**Files:** `README.md`, `CHANGELOG.md`, `AGENTS.md`, `CLAUDE.md`

- [ ] **Step 1: README tiers** — add V4.1 Flash rows: Q2 ≥128 GiB with automatic SSD streaming (341 GiB on disk, 152 GiB resident) and ≥256 GiB full residency; Q4 ≥256 GiB streaming / 512 GiB full residency (483 GiB on disk, 294 GiB resident). Keep 0731 rows.
- [ ] **Step 2: CHANGELOG** — V4.1 Flash support, ds4 bump to `bd66c40` (199 commits), two-part Q4 with SHA-256 verified join, auto SSD streaming/forced power 100, no ctx floor for V4.1 max think.
- [ ] **Step 3: AGENTS.md / CLAUDE.md** — pin `bd66c4020`; V4.1 estimator mirrored separately; 0731/Pro formulas and ids verified byte-identical; think-max patch still applies (0731/Pro-only).
- [ ] **Step 4: Commit** `docs: V4.1 Flash memory tiers and ds4 pin`

---

### Task 11: Full verification

- [ ] **Step 1: CI-equivalent locally**

```bash
swift format lint --strict --recursive Sources Tests
swift build -c release -Xswiftc -warnings-as-errors
swift test
bash scripts/apply-ds4-patches.sh
make -C external/ds4 -j ds4-server
DS4_SRC=external/ds4 bash build.sh
test -x "DS4 Control.app/Contents/MacOS/DS4Control"
test -x "DS4 Control.app/Contents/Resources/ds4/ds4-server"
```
Expected: all exit 0.

- [ ] **Step 2: Verify pinned byte data against Hugging Face** (read-only blob API) — sizes/shas match Task 5 constants.

- [ ] **Step 3: Optional on-hardware smoke** — `scripts/flash41-mem-harness.sh` on a 128 GiB+ Mac with Q2 downloaded; record actuals.

- [ ] **Step 4: Final commit + PR** once all green.

---

## Self-review notes

- **Coverage:** submodule pin, model constants, feasibility mirror (AGENTS.md re-verification rule satisfied by Task 3 Steps 1–2 plus 0731/Pro regression literals), launch flags, two-part native download, SHA-256, UI, agents, harness, docs, CI verification.
- **Decisions honored:** 0731 kept (floor ≥96, default <128 GiB; stored selections never auto-migrate); V4.1 floor ≥128; native two-part Q4; three thinking modes with a variant-aware Max gate.
- **Residual risks:** the streaming non-routed constant (Task 3 Step 1) has a documented extraction procedure and a conservative fallback; `ds41GraphBytes` literals come from a verbatim C transcription cross-check (Task 3 Step 2), with the harness as the on-hardware backstop.
