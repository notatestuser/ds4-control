# DS4 Control — project guide for Claude

## Purpose

A macOS **menu-bar control pane** for **DeepSeek V4** running locally on Apple Silicon via
[antirez/ds4](https://github.com/antirez/ds4). It launches, supervises, and monitors a local
`ds4-server` child process; lets you pick **V4 Pro** (0813), **V4.1 Flash**, or **V4 Flash** (0731);
downloads GGUF weights; shows live unified-memory / GPU / CPU / power widgets; provides a built-in
chat; and can open a coding agent (pi or claude) in Terminal pointed at the local server.

It does **no embedded inference** — all inference is delegated to `ds4-server`. This app only
supervises that process and surfaces system metrics + a chat/agent front end.

## DeepSeek V4 release maintenance

The app pins the official Flash 0731, V4.1 Flash, and Pro 0813 GGUF generations. Pro 0813's Hub LFS
metadata reports exactly 464,627,334,560 bytes — the same byte size as the preview file but a
different content hash — and this value is baked into `Quant.ggufBytes`. V4.1 Flash's exact totals,
part sizes, and SHA-256 digests live in `Quant` (`ggufBytes`, `downloadParts`, `sha256`); its
resident main-weight byte counts subtract the 202,778,032,400 B of disk-only Engram tables that
ds4 `munmap`s at load.

`external/ds4` is the upstream [antirez/ds4](https://github.com/antirez/ds4) submodule, pinned to
the V4.1-Flash-support commit `bd66c4020`. THINK_MAX is applied on top via
`patches/ds4-think-max.patch` (`scripts/apply-ds4-patches.sh`) because upstream still emits the
official 0731/0813 **high** prefix for `reasoning_effort: max` (antirez/ds4#635); V4.1 uses numeric
reasoning effort and is unaffected. The Metal context-allocation formula, shared graph workspace,
per-session graph allocations, and persistent backend-scratch bounds were verified byte-identical
for 0731/Pro between the previous pin (`c35cf38`) and `bd66c4020`. V4.1 has its own estimator
(`ds41_graph_bytes` / `ds41_memory_admit_for_host`), mirrored as `ds41GraphBytes` +
`v41FixedWiredMB` in `Feasibility.swift` with pinned constants and tests. If a future ds4 bump
changes any allocator or shape assumption, re-verify `Feasibility.swift` and the
feasibility/memory-tier tests before release.

## Stack

- SwiftPM executable target `DS4Control` (Swift 6 mode, macOS 14+). `swift-tools-version: 6.3`.
- SwiftUI menu-bar app (`MenuBarExtra`, LSUIElement/`.accessory` — no dock icon or window until
  you click the menu-bar item). Links `IOKit` + private `IOReport` for power/frequency metrics.
- `ds4` lives as a git submodule at `external/ds4` (provides the `ds4-server` binary).

## Dev workflow

From the repo root (`/Users/luke/dev26/ds4_workspace/ds4-control`):

```bash
swift build          # build
swift test           # run all tests (authoritative — trust the compiler over SourceKit squiggles)
bash scripts/apply-ds4-patches.sh && make -C external/ds4 -j ds4-server
DS4_DIR="$PWD/external/ds4" .build/debug/DS4Control     # run the dev app
```

`DS4_DIR` points the app at the bundled submodule so Start can spawn `ds4-server`. It's a menu-bar
app — after launch, find its icon in the macOS menu bar; the popup's gear/chat/terminal icons open
Settings, the chat window, and the agent launcher.

Detached run used in agent sessions (survives the shell, logs to a file):
```bash
pkill -f '.build/debug/DS4Control'
DS4_DIR="$PWD/external/ds4" nohup ./.build/debug/DS4Control >/tmp/ds4control-dev.log 2>&1 &
disown
```

- `scripts/flash-mem-harness.sh` — manual harness that boots the real Flash 0731 model at various
  context sizes and samples resident memory (NOT part of `swift test`; loads ~81 GB).
- `scripts/flash41-mem-harness.sh` — the V4.1 equivalent: `--ssd-streaming --power 100` on a
  128 GiB+ Mac, cross-checks ds4's `ds4: memory:` plan against the `Feasibility` mirror (loads a
  341 GiB GGUF; Engram rows stay on disk).
- CI: `.github/workflows/ci.yml` (build + test, bundles ds4), `release.yml` (tag-triggered
  Developer ID signed + notarized release).

## Architecture

Entry point `DS4ControlApp.swift` (`@main`) builds one `AppState`, one `SupervisorService`, one
`MetricsManager`, one `ChatViewModel`, and wires them into the `MenuBarExtra` + windows.

| Area | Files | Role |
|---|---|---|
| State | `AppState.swift` | Persisted user prefs (port, ctxOverride, variant, flashQuant, flash41Quant, kvDiskCache, thinkingMode, concurrentSessions). Pattern: `@Published var X { didSet { d.set(X, forKey:) } }` + read-back in `init`. |
| Supervisor | `Services/SupervisorService.swift`, `ProcessRunner.swift`, `ReadinessMatcher.swift`, `HFDownloader.swift`, `ChunkFetcher.swift`, `ChunkBitmap.swift`, `DownloadProbe.swift`, `GGUFJoiner.swift` | Spawns/monitors `ds4-server` (stderr readiness, health poll, graceful stop, crash detect); downloads GGUF weights with a native parallel chunked downloader (offset writes + an on-disk bitmap sidecar for resume-across-restarts); verifies SHA-256 and joins split parts (V4.1 Q4); owns the on-disk KV cache dir. |
| Models | `Model/Variant.swift`, `Feasibility.swift`, `ServerState.swift` | `Variant` (pro/flash/flash41: layers, exact GGUF sizes, ctxCeiling, modelId, quants) and `QuantSelection` (resolved variant+quant). `Feasibility` mirrors the pinned ds4 Metal context allocator for the RAM/wired-limit gate, plus the separate V4.1 `ds41GraphBytes`/`v41FixedWiredMB` path; owns `defaultCtx`, `defaultFlashQuant`, `defaultFlash41Quant`, and the `thinkMax` threshold (393,216; 0731/Pro only). |
| Metrics | `Metrics/*` | IOReport/IOKit sampling (memory/GPU/CPU/power) on a 2 s timer; `MetricsManager` + per-collector files + `SparklineView` history. |
| Chat | `Services/ChatService.swift`, `ChatSSEParser.swift`, `ViewModels/ChatViewModel.swift`, `Views/ChatView.swift`, `MarkdownText.swift` | Streams `ds4-server` `/v1/chat/completions` (SSE). `content` → answer, `reasoning_content` → a collapsible "thinking" section. `MarkdownText` is a selectable NSTextView markdown renderer + light LaTeX cleanup. |
| Agent launcher | `Services/AgentLauncher.swift` | Generates a wrapper shell script + `osascript` to open Terminal running pi/claude against the local server (Max-Think prompt, env vars, bundled pi `models.json`). |
| Views | `Views/PopupView.swift`, `SettingsView.swift`, `ModelRowView.swift`, `MetricCardView.swift` | Menu-bar popup (model selector + metric cards + gear/chat/terminal icons), Settings, feasibility row. |
| Misc | `Paths.swift`, `WindowChrome.swift` | App-support dirs (gguf, pi-agent); accessory↔regular window switching for proper chat/settings windows. |
