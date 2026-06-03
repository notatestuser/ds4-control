# DS4 Control — project guide for Claude

## Purpose

A macOS **menu-bar control pane** for **DeepSeek V4** running locally on Apple Silicon via
[antirez/ds4](https://github.com/antirez/ds4). It launches, supervises, and monitors a local
`ds4-server` child process; lets you pick **V4 Pro** or **V4 Flash**; downloads GGUF weights;
shows live unified-memory / GPU / CPU / power widgets; provides a built-in chat; and can open a
coding agent (pi or claude) in Terminal pointed at the local server.

It does **no embedded inference** — all inference is delegated to `ds4-server`. This app only
supervises that process and surfaces system metrics + a chat/agent front end.

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

- `scripts/flash-mem-harness.sh` — manual harness that boots the real Flash model at various
  context sizes and samples resident memory (NOT part of `swift test`; loads ~81 GB).
- CI: `.github/workflows/ci.yml` (build + test, bundles ds4), `release.yml` (tag-triggered
  Developer ID signed + notarized release).

## Architecture

Entry point `DS4ControlApp.swift` (`@main`) builds one `AppState`, one `SupervisorService`, one
`MetricsManager`, one `ChatViewModel`, and wires them into the `MenuBarExtra` + windows.

| Area | Files | Role |
|---|---|---|
| State | `AppState.swift` | Persisted user prefs (port, ctxOverride, variant, flashQuant, kvDiskCache, thinkMaxChat). Pattern: `@Published var X { didSet { d.set(X, forKey:) } }` + read-back in `init`. |
| Supervisor | `Services/SupervisorService.swift`, `ProcessRunner.swift`, `ReadinessMatcher.swift`, `HFDownloader.swift`, `ChunkFetcher.swift`, `ChunkBitmap.swift`, `DownloadProbe.swift` | Spawns/monitors `ds4-server` (stderr readiness, health poll, graceful stop, crash detect); downloads GGUF weights with a native parallel chunked downloader (offset writes + an on-disk bitmap sidecar for resume-across-restarts); owns the on-disk KV cache dir. |
| Models | `Model/Variant.swift`, `Feasibility.swift`, `ServerState.swift` | `Variant` (pro/flash: layers, kvBytesPerToken, ctxCeiling, modelId, quants). `Feasibility` = RAM gate, `defaultCtx` (RAM-tiered), `defaultFlashQuant`, `thinkMax` threshold (393,216). |
| Metrics | `Metrics/*` | IOReport/IOKit sampling (memory/GPU/CPU/power) on a 2 s timer; `MetricsManager` + per-collector files + `SparklineView` history. |
| Chat | `Services/ChatService.swift`, `ChatSSEParser.swift`, `ViewModels/ChatViewModel.swift`, `Views/ChatView.swift`, `MarkdownText.swift` | Streams `ds4-server` `/v1/chat/completions` (SSE). `content` → answer, `reasoning_content` → a collapsible "thinking" section. `MarkdownText` is a selectable NSTextView markdown renderer + light LaTeX cleanup. |
| Agent launcher | `Services/AgentLauncher.swift` | Generates a wrapper shell script + `osascript` to open Terminal running pi/claude against the local server (Max-Think prompt, env vars, bundled pi `models.json`). |
| Views | `Views/PopupView.swift`, `SettingsView.swift`, `ModelRowView.swift`, `MetricCardView.swift` | Menu-bar popup (model selector + metric cards + gear/chat/terminal icons), Settings, feasibility row. |
| Misc | `Paths.swift`, `WindowChrome.swift` | App-support dirs (gguf, pi-agent); accessory↔regular window switching for proper chat/settings windows. |
