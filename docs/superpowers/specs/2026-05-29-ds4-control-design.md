# DS4 Control — Design Spec

**Date:** 2026-05-29
**Status:** Approved-pending-review
**Repo (working name):** `ds4-control` · App: *DS4 Control* · Binary: `DS4Control`

## 1. Overview

A polished macOS **menu-bar control pane for DeepSeek V4 via `ds4`**. It launches, supervises, and monitors the external `ds4-server`, lets the user pick **V4 Pro or V4 Flash**, and shows mini resource-monitoring widgets (unified memory, GPU, power/ANE, CPU) in the popup.

It is deliberately **not** a generic model runner. There is no model search, no chat UI, no multi-model registry, no inference code of its own. All inference is delegated to `ds4-server`; all downloads are delegated to ds4's shipped `download_model.sh`.

**Implementation: 100% Swift, single binary.** It borrows the **`ServerManager` supervision pattern from `mlx-serve`** (a Swift `Foundation.Process` that spawns a server binary, captures stderr, detects readiness, and handles crashes) and the **mini-widget aesthetic + collectors of `mac-resource-monitor`**, but is far simpler than either. No Zig, no second toolchain, no inter-process protocol.

### Goals
- One-click start/stop of `ds4-server` from the menu bar, with clear state feedback.
- Pro/Flash selection with a smart default driven by system RAM.
- Delegate model downloads to `download_model.sh` with live progress.
- Compact, attractive resource widgets sized for an LLM workstation (memory is the hero metric).
- Public-repo quality: comprehensive tests, strict CI gate, clean docs, signed with the user's Apple Development identity.

### Non-goals
- No chat / completions UI, no agent loop, no tools.
- No multi-model hot-swap, no model browser/search.
- No embedded inference engine.
- No notarized public distribution in v1 (dev-signed; others build/self-sign).

## 2. Architecture

```
┌──────────────────  DS4 Control.app  (Swift only)  ──────────────────┐
│  SwiftUI — MenuBarExtra(.window), LSUIElement                        │
│   • Pro/Flash selector + Start/Stop/Download                         │
│   • mini metric cards (mem / GPU / power-ANE / CPU)                   │
│   • download progress                                                │
│                                                                      │
│  SupervisorService  (ObservableObject)                               │
│   • Foundation.Process → ds4-server  (spawn / SIGTERM)               │
│   • capture stderr → readiness "listening on http://"               │
│   • URLSession health poll  GET /v1/models                           │
│   • Process → download_model.sh, parse curl % → progress             │
│   • published @State: ServerState, model, port, ctx, downloadPct     │
│                                                                      │
│  MetricsManager + collectors (Mach / IOKit / IOReport)               │
│   • 2 s timer → SystemSnapshot → sparkline history                   │
└──────────────────────────────┬───────────────────────────────────────┘
                               ▼ spawns / SIGTERM
                     ds4-server (external C binary, 127.0.0.1:8000)
```

Two cooperating Swift subsystems, no second binary:
- **`SupervisorService`** = *own the ds4 lifecycle.* Process control, readiness/health detection, downloads, state — all in Swift, with the string-parsing pieces factored into pure, unit-testable functions.
- **`MetricsManager` + collectors** = *sample the machine.* Reused from `mac-resource-monitor`, driven by a 2 s timer.

The SwiftUI views observe both via `@Published` state.

## 3. Component: `SupervisorService` (Swift)

An `ObservableObject` owning a single `ds4-server` child via `Foundation.Process`. Public API is intent-based; UI binds to published state.

### 3.1 Public API
| Method | Params | Effect |
|---|---|---|
| `start` | `variant` (`.pro`\|`.flash`), `ctx` Int, `port` Int, `power` Int? | Resolve gguf path; spawn `ds4-server`; `starting`→`ready`. |
| `stop` | — | SIGTERM child; await graceful exit; `stopping`→`idle`. |
| `download` | `variant` | Run `download_model.sh <arg>`; publish progress; on success mark variant available. |
| `refreshAvailability` | — | Recompute which variants have a gguf on disk. |

### 3.2 Published state
- `state: ServerState` ∈ `idle` \| `downloading` \| `starting` \| `ready` \| `stopping` \| `error(ServerError)`
- `activeModel: String?` (`deepseek-v4-pro` / `deepseek-v4-flash`), `port`, `ctx`, `thinkMax: Bool` (`ctx >= 393216`), `pid`
- `download: DownloadProgress?` (`pct`, `file`, `receivedBytes`, `totalBytes?`)
- `health: HealthStatus?` (`ok`, `latencyMs`), `availableVariants: Set<Variant>`
- `recentLog: [LogLine]` (rolling buffer of ds4-server stderr, for an error disclosure view)

### 3.3 Internals
- **Spawn:** `ds4-server -m <gguf> --ctx <ctx> --host 127.0.0.1 --port <port> --metal [--power <n>]`, `currentDirectoryURL` = ds4 directory. Read child stderr via a `Pipe` `readabilityHandler`, line-buffered.
- **Readiness matcher** *(pure fn `isReadyLine(_:) -> Bool`)*: detect a line containing `listening on http://` → `starting`→`ready`. Startup timeout (default 600 s; Pro load is slow) → `error(.startupTimeout)`.
- **Health poll:** once `ready`, `URLSession` `GET http://127.0.0.1:<port>/v1/models` every 5 s; publish `health`. 3 consecutive failures while process alive → `error(.unhealthy)`. Child exit while expected-alive → `error(.crashed)` with stderr tail.
- **Stop:** SIGTERM, wait up to 30 s for graceful KV-cache flush, else SIGKILL.
- **Download:** spawn `download_model.sh <arg>` (cwd = ds4 dir), parse curl `--progress-meter` output via pure fn `parseCurlProgress(_:) -> Double?` (CR-delimited `%` field) → `DownloadProgress`. `--token` passed only if the user supplied one (else the script's own `HF_TOKEN`/cache logic). Non-zero exit → `error(.downloadFailed)`.

### 3.4 ds4 directory + model path resolution
- ds4 directory (persisted, §4.5) must contain executable `ds4-server` + `download_model.sh`; otherwise `error(.ds4DirInvalid)` naming the missing file.
- `download_model.sh` symlinks `<ds4dir>/ds4flash.gguf` to the selected gguf, but that symlink is shared across variants. To stay unambiguous, the supervisor resolves the **explicit** gguf filename per variant from a known filename table, located under `$DS4_GGUF_DIR` or `<ds4dir>/gguf`, and passes it via `-m`. File present ⇒ "downloaded"; absent ⇒ Download.

### 3.5 State machine
`idle → downloading → idle` (download) and `idle → starting → ready → stopping → idle` (run). Any state may go to `error`; `error` clears to `idle` on the next valid command. Calls invalid for the current state are no-ops that surface a transient message (never crash).

## 4. Component: SwiftUI app

`MenuBarExtra(.window)` scene, `LSUIElement=true` (menu-bar only, no Dock icon).

### 4.1 Menu-bar icon
Template image, tinted by state: **gray** idle · **orange** downloading/starting · **green** ready · **red** error. Driven by `SupervisorService.state`.

### 4.2 Popup layout (~320 pt wide)
1. **Header** — app name + status dot + state label (e.g. "Ready · V4 Pro · :8000 · Think-Max").
2. **Model row** — segmented **Pro / Flash** (default per §5.2; **Pro shown only when RAM ≥ 512 GB**, otherwise Flash-only) + **Start/Stop**. If the selected variant's gguf is absent, the action becomes **Download** (size shown).
3. **Download progress** — visible only while `downloading`: bar + `% / received / total / file`.
4. **Mini metric cards** — §4.4.
5. **Footer** — gear → Settings; quit.

### 4.3 Resource collectors (ported from `mac-resource-monitor`)
Reuse the self-contained collectors + snapshot model: CPU (`host_processor_info`), Memory (`host_statistics64` + `hw.memsize` + `vm.swapusage`), GPU (`IOAccelerator` registry), Power/ANE (`IOReport` Energy Model via `@_silgen_name` FFI), Architecture detection. Driven by a 2 s `MetricsManager` timer with a history ring buffer for sparklines.

### 4.4 Mini widgets (shrunk from `MetricCardView`/`SparklineView`/`ValueGaugeView`)
| Card | Primary | Detail | Why |
|---|---|---|---|
| **Unified Memory** (hero) | used/total %, ring gauge | used GB / total GB, pressure (nominal/warn/crit) | Pro resident set ≈ 430 GB — decides whether it runs at all. |
| **GPU** | util %, sparkline | core count | Inference is GPU-bound (Metal). |
| **Power / ANE** | total W, sparkline | CPU / GPU / ANE watts | "Is it working" + thermal headroom. |
| **CPU** | util %, sparkline | — | Prefill / host overhead. |

Thermal/disk/network omitted (low signal here). Cards use `.ultraThinMaterial` + severity-colored stroke; severity green/orange/red.

### 4.5 Settings (small sheet)
- **ds4 directory** picker (must contain `ds4-server` + `download_model.sh`).
- **Context size** (default is **RAM-tiered**, §5.2; range 1 … 1,000,000 = model ceiling; badges "Think-Max" when ≥ 393216).
- **Port** (default 8000).
- **GPU power duty** (1–100, default 100).
- Optional **HF token** (else ds4 script's `HF_TOKEN`/cache).
- Persisted in `UserDefaults`.

## 5. ds4 integration specifics

### 5.1 RAM detection
`sysctl hw.memsize` → GB. Drives offered variants, default variant, and default context.

### 5.2 RAM tiers → variants + default context
Model context ceiling is **1,000,000 tokens**; KV cache is heavily compressed. Per ds4 README, Flash runs on 128 GB (and reportedly 96 GB *at ≤ 250k context*), Pro on 512 GB-class only.

| RAM | Variants offered | Default variant | Default ctx | Think-Max? |
|---|---|---|---|---|
| **≥ 512 GB** | Pro + Flash | **Pro** | 393216 | yes |
| **97–511 GB** | Flash only | Flash | 393216 | yes |
| **≤ 96 GB** | Flash only | Flash | **250000** | no |

Rationale: 393216 is the Think-Max threshold and the "best juice" default on capable machines; ≤ 96 GB drops to 250000 to stay within memory headroom (README). All values are user-overridable up to the 1M ceiling. On ≥ 512 GB the Pro resident set (~430 GB) leaves limited headroom — the Memory hero card surfaces pressure, and ctx can be lowered if Pro proves tight at 393216.

### 5.3 Variant → download arg + gguf
| Variant | RAM | `download_model.sh` arg | gguf (approx size) |
|---|---|---|---|
| **Pro** | ≥ 512 GB | `pro-imatrix` | `…Pro-IQ2XXS…-imatrix.gguf` (~430 GB) |
| **Flash** | ≥ 256 GB | `q4-imatrix` | `…Flash-Q4K…-imatrix.gguf` (~153 GB) |
| **Flash** | < 256 GB | `q2-imatrix` | `…Flash-IQ2XXS…-imatrix.gguf` (~81 GB) |

### 5.4 Launch flags
`ds4-server -m <resolved.gguf> --ctx <ctx> --host 127.0.0.1 --port 8000 --metal [--power <n>]`, cwd = ds4 directory. `<ctx>` = the RAM-tiered default (§5.2) unless overridden. At ≥ 393216 this unlocks **Think-Max** and the full 384K output budget (`max_completion = min(default_tokens, ctx)`).

### 5.5 Readiness / health / stop
- Ready: stderr `listening on http://127.0.0.1:<port>`.
- Health: `GET /v1/models` → 200 with `deepseek-v4-pro`/`deepseek-v4-flash` in the list.
- Stop: SIGTERM (graceful KV flush) → SIGKILL fallback.

### 5.6 Disk-space pre-check
Before download, compare free space on the gguf volume to the variant's approx size; warn (non-blocking) if short.

## 6. Build, packaging & signing

- **Build system:** Swift Package Manager (executable target), like `mac-resource-monitor`. Links `IOKit` + private `IOReport`. macOS 14+ deployment target.
- **Bundle:** top-level `build.sh` runs `swift build -c release`, assembles `DS4 Control.app` (`Contents/MacOS/DS4Control`), writes `Info.plist` (`LSUIElement`, `NSAllowsLocalNetworking`), generates `AppIcon.icns`.
- **Signing:** **Apple Development identity** (Xcode dev cert), auto-detected via `security find-identity -v -p codesigning | grep "Apple Development"`. No hardened-runtime/notarization in v1. README documents self-signing for other users.
- **Single binary** — no Zig, no `build.zig`, no second toolchain.

## 7. Testing & QA gate

### 7.1 Swift unit tests (`swift test`)
- **Pure parser fns:** `isReadyLine`, `parseCurlProgress`, variant → script-arg + gguf-filename mapping; **RAM-tier logic** (offered variants, default variant, default ctx: ≤96→250000/Flash, 97–511→393216/Flash, ≥512→393216/Pro), Think-Max boundary (393216).
- **Supervisor logic:** state-machine transitions, illegal-command no-ops, error mapping, stderr-tail capture.
- **Collectors:** memory math, percent clamping, severity thresholds; event/snapshot decode resilience to malformed input.
- **RAM → default-variant** logic; settings validation/persistence.

### 7.2 Integration (model-free)
- **Fake `ds4-server`** stub script: prints `listening on http://127.0.0.1:<port>`, serves a minimal `/v1/models`. Exercises full supervision (start→ready→health→stop, crash detection) **without** the 430 GB model.
- **Fake `download_model.sh`** stub: emits synthetic curl-style progress for the progress parser/state path.

### 7.3 CI gate (GitHub Actions, macOS runner) — merge blocked on any failure
- `swift-format --lint` (formatting enforced).
- **Zero compiler warnings.**
- Release build of the Swift app.
- `swift test` green (unit + integration with stubs).
- App-bundle assembly + smoke launch (headless `--version`/sanity).

## 8. Repo polish

- **README:** what/why, screenshots/GIF, prerequisites (built `ds4`, a downloaded model), build, run, signing notes, troubleshooting.
- **LICENSE** + **attribution:** credit `mac-resource-monitor` and, transitively, `macmon` (MIT) for the IOReport approach.
- **CHANGELOG.md** (CalVer `YY.M.N`).
- **.gitignore** (`.build/`, `*.app`, `gguf/`, `*.xcuserstate`).
- CI badge.

## 9. Success criteria
1. From a clean menu-bar launch: pick Pro (auto-default on 512 GB), Start, watch the icon go orange→green and memory climb to the resident set — without touching a terminal.
2. Stop returns cleanly to idle (graceful SIGTERM).
3. Selecting an undownloaded variant offers Download with live progress, delegated to `download_model.sh`.
4. Mini widgets refresh at 2 s and read plausibly against `mac-resource-monitor`.
5. `swift test` (unit + stub integration), `swift-format` lint, and a zero-warning release build all pass in CI.

## 10. Open questions
None outstanding. (Name, metric set, **RAM-tiered ctx** — 393216/Think-Max on ≥97 GB, 250000 on ≤96 GB — **Pro gated to ≥512 GB**, external ds4-dir, and pure-Swift single-binary architecture all resolved with the user.)
