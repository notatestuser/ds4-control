# DS4 Control — Design Spec

**Date:** 2026-05-29
**Status:** Approved-pending-review
**Repo (working name):** `ds4-control` · App: *DS4 Control* · Zig binary: `ds4ctl`

## 1. Overview

A polished macOS **menu-bar control pane for DeepSeek V4 via `ds4`**. It launches, supervises, and monitors the external `ds4-server`, lets the user pick **V4 Pro or V4 Flash**, and shows mini resource-monitoring widgets (unified memory, GPU, power/ANE, CPU) in the popup.

It is deliberately **not** a generic model runner. There is no model search, no chat UI, no multi-model registry, no inference code of its own. All inference is delegated to `ds4-server`; all downloads are delegated to ds4's shipped `download_model.sh`.

Lineage: keeps the **two-binary bundle pattern of `mlx-serve`** (a Zig binary + a SwiftUI app shipped together in one `.app`) and the **mini-widget aesthetic of `mac-resource-monitor`**, but far simpler than either.

### Goals
- One-click start/stop of `ds4-server` from the menu bar, with clear state feedback.
- Pro/Flash selection with a smart default driven by system RAM.
- Delegate model downloads to `download_model.sh` with live progress.
- Compact, attractive resource widgets sized for an LLM workstation (memory is the hero metric).
- Public-repo quality: comprehensive tests, strict CI gate, clean docs, signed with the user's Apple Development identity.

### Non-goals
- No chat / completions UI, no agent loop, no tools.
- No multi-model hot-swap, no model browser/search.
- No embedded inference engine (Zig or otherwise).
- No notarized public distribution in v1 (dev-signed; others build/self-sign).

## 2. Architecture

```
┌──────────────  DS4 Control.app  ──────────────┐
│  Swift — SwiftUI MenuBarExtra(.window)         │
│   • Pro/Flash selector + Start/Stop            │
│   • mini metric cards (mem/GPU/power/CPU)       │
│   • download progress                          │
│   • native resource collectors (Mach/IOKit/    │
│     IOReport)                                   │
│        │ stdin: JSON commands                   │
│        ▼ stdout: JSON events                    │
│   ┌────────────────────────────────────────┐   │
│   │  ds4ctl  (Zig — ds4 lifecycle brain)    │   │
│   │   • spawn/stop ds4-server               │   │
│   │   • parse readiness "listening on http" │   │
│   │   • poll health GET /v1/models          │   │
│   │   • run download_model.sh, stream %     │   │
│   │   • state machine + error reporting     │   │
│   └───────────────────┬─────────────────────┘   │
└───────────────────────┼─────────────────────────┘
                        ▼ spawns / SIGTERM
              ds4-server (external C binary, 127.0.0.1:8000)
```

**Boundary (single responsibility each):**
- **Zig `ds4ctl`** = *own the ds4 lifecycle.* Process control, readiness/health detection, downloads, state. No UI, no resource sampling. Pure, fully unit-testable logic.
- **Swift app** = *draw + sample the machine.* Menu-bar UI, widgets, and native resource collectors. Talks to `ds4ctl` as a child process via a line-delimited JSON protocol.

Rationale: `ds4ctl` is the part that benefits most from Zig (precise process/IO control, easy to test in isolation, reuses `mlx-serve`'s `build.zig`/bundling lineage). Resource sampling stays in Swift because the proven collector + widget code already exists in `mac-resource-monitor` and is tightly coupled to SwiftUI rendering.

## 3. Component: Zig `ds4ctl`

A long-running child process of the Swift app. Reads commands on **stdin**, emits events on **stdout**, both newline-delimited JSON (one object per line). Human logs go to **stderr**.

### 3.1 Commands (Swift → ds4ctl, stdin)
| Command | Fields | Effect |
|---|---|---|
| `start` | `variant` (`"pro"`\|`"flash"`), `ctx` (int), `port` (int), `power` (int, optional 1–100) | Resolve gguf path; spawn `ds4-server`; transition `starting`→`ready`. |
| `stop` | — | SIGTERM `ds4-server`; await graceful exit; `stopping`→`idle`. |
| `download` | `variant` | Run `download_model.sh <mapped-arg>`; stream `download` events; on success update model availability. |
| `status` | — | Re-emit current `state` event. |
| `shutdown` | — | Stop ds4-server if running, then exit `ds4ctl`. |

### 3.2 Events (ds4ctl → Swift, stdout)
| Event | Fields |
|---|---|
| `state` | `state` ∈ `idle`\|`downloading`\|`starting`\|`ready`\|`stopping`\|`error`; `model`; `port`; `ctx`; `thinkMax` (bool, `ctx>=393216`); `pid` |
| `download` | `pct` (0–100, float), `file`, `receivedBytes`, `totalBytes` (nullable) |
| `health` | `ok` (bool), `latencyMs` (int) |
| `error` | `kind` (enum), `message`, `detail` |
| `log` | `line`, `source` (`ds4ctl`\|`ds4-server`\|`download`) |

### 3.3 Internals
- **Spawn:** `ds4-server -m <gguf> --ctx <ctx> --host 127.0.0.1 --port <port> --metal [--power <n>]`, working dir = ds4 directory (`--chdir`). Capture child stderr line-by-line.
- **Readiness matcher:** detect the line containing `listening on http://` → transition `starting`→`ready`. Timeout (default 600 s, model load can be slow for Pro) → `error`/`startup_timeout`.
- **Health poller:** once `ready`, `GET http://127.0.0.1:<port>/v1/models` every 5 s; emit `health`. Repeated failure (3×) while process alive → `error`/`unhealthy`; process exit → `error`/`crashed` (with tail of captured stderr).
- **Stop:** SIGTERM, wait up to 30 s for graceful KV-cache flush, then SIGKILL fallback.
- **Download:** spawn `download_model.sh <arg>` (cwd = ds4 dir), parse curl `--progress-meter` output (carriage-return-delimited `%` field) → `download` events. Pass `--token` only if a token is supplied by Swift (else the script's own `HF_TOKEN`/cache logic applies). Non-zero exit → `error`/`download_failed`.

### 3.4 ds4 directory discovery
`ds4ctl` receives the ds4 directory path from Swift (resolved/persisted there). It validates the directory contains executable `ds4-server` and `download_model.sh`; missing → `error`/`ds4_dir_invalid` with which file is absent.

### 3.5 State machine
`idle → downloading → idle` (download path) and `idle → starting → ready → stopping → idle` (run path). Any state can transition to `error`; `error` clears to `idle` on next valid command. Illegal commands for the current state are rejected with an `error`/`bad_state` event (no crash).

## 4. Component: Swift app

`MenuBarExtra(.window)` scene, `LSUIElement=true` (menu-bar only, no Dock icon). Spawns and supervises `ds4ctl` via `Foundation.Process` (mirrors `mlx-serve`'s `ServerManager`).

### 4.1 Menu-bar icon
Template image, tinted by state: **gray** idle · **orange** downloading/starting · **green** ready · **red** error. Driven by the latest `state` event.

### 4.2 Popup layout (~320 pt wide)
1. **Header** — app name + status dot + state label (e.g. "Ready · V4 Pro · :8000 · Think-Max").
2. **Model row** — segmented control **Pro / Flash** (default per §5.2) + **Start/Stop** button. Disabled appropriately by state. If the selected variant's gguf is absent, button becomes **Download** (size shown).
3. **Download progress** — visible only while `downloading`: bar + `% / received / total / file`.
4. **Mini metric cards** — see §4.4.
5. **Footer** — gear → Settings; quit.

### 4.3 Resource collectors (ported from `mac-resource-monitor`)
Reuse the self-contained collectors and snapshot model: CPU (`host_processor_info`), Memory (`host_statistics64` + `hw.memsize` + `vm.swapusage`), GPU (`IOAccelerator` registry), Power/ANE (`IOReport` Energy Model via `@_silgen_name` FFI), Architecture detection. Driven by a 2 s `MetricsManager` timer. History ring buffer for sparklines.

### 4.4 Mini widgets (shrunk from `MetricCardView`/`SparklineView`/`ValueGaugeView`)
| Card | Primary | Detail | Why |
|---|---|---|---|
| **Unified Memory** (hero) | used/total %, ring gauge | used GB / total GB, pressure (nominal/warn/crit) | Pro resident set ≈ 430 GB — the metric that decides whether it runs. |
| **GPU** | util %, sparkline | core count | Inference is GPU-bound (Metal). |
| **Power / ANE** | total W, sparkline | CPU / GPU / ANE watts | "Is it actually working" + thermal headroom. |
| **CPU** | util %, sparkline | — | Prefill/host overhead. |

Thermal/disk/network are intentionally omitted (low signal for this use). Each card uses `.ultraThinMaterial` + severity-colored stroke; severity green/orange/red.

### 4.5 Settings (small sheet)
- **ds4 directory** picker (must contain `ds4-server` + `download_model.sh`).
- **Context size** (default **393216**; field validates ≥ 1; UI badges "Think-Max" when ≥ 393216).
- **Port** (default 8000).
- **GPU power duty** (1–100, default 100).
- Persisted in `UserDefaults`.

## 5. ds4 integration specifics

### 5.1 RAM detection
`sysctl hw.memsize` → GB. Drives the default variant and download recommendations.

### 5.2 Variant mapping & default
| UI choice | RAM | `download_model.sh` arg | gguf (approx size) |
|---|---|---|---|
| **Pro** | (any; intended ≥ 512 GB) | `pro-imatrix` | `…Pro-IQ2XXS…-imatrix.gguf` (~430 GB) |
| **Flash** | ≥ 256 GB | `q4-imatrix` | `…Flash-Q4K…-imatrix.gguf` (~153 GB) |
| **Flash** | < 256 GB | `q2-imatrix` | `…Flash-IQ2XXS…-imatrix.gguf` (~81 GB) |

**Default selection:** RAM ≥ 512 GB ⇒ **Pro**; otherwise **Flash**.

### 5.3 Model path resolution
`download_model.sh` symlinks `<ds4dir>/ds4flash.gguf` → selected gguf, but that symlink is shared between variants. To avoid ambiguity, `ds4ctl` resolves the **explicit** gguf filename for the chosen variant (from the known filename table, located under `$DS4_GGUF_DIR` or `<ds4dir>/gguf`) and passes it via `-m`. Presence of that file = "downloaded"; absence ⇒ Download button.

### 5.4 Launch flags
`ds4-server -m <resolved.gguf> --ctx 393216 --host 127.0.0.1 --port 8000 --metal [--power <n>]` with cwd/`--chdir` = ds4 directory. Default ctx 393216 unlocks Think-Max and sets the full 384K output budget.

### 5.5 Readiness / health / stop
- Ready: stderr `listening on http://127.0.0.1:<port>`.
- Health: `GET /v1/models` 200 with `deepseek-v4-pro`/`deepseek-v4-flash` in list.
- Stop: SIGTERM (graceful KV flush) → SIGKILL fallback.

### 5.6 Disk-space pre-check
Before download, compare free space on the gguf volume to the variant's approx size; warn (non-blocking) if short.

## 6. Build, packaging & signing

- **Swift app:** Swift Package Manager (executable target), like `mac-resource-monitor`. Links `IOKit` + private `IOReport`. macOS 14+ deployment target.
- **`ds4ctl`:** `build.zig` (latest stable Zig, fetched; matches `mlx-serve`'s ≥ 0.16 baseline). Health check is a minimal raw-TCP HTTP GET (`GET /v1/models HTTP/1.1` to `127.0.0.1:<port>`, read status line) — no macOS frameworks needed; pure `std` sockets only.
- **Bundle:** top-level `build.sh` builds both, assembles `DS4 Control.app` (`Contents/MacOS/DS4Control` + `Contents/MacOS/ds4ctl`), writes `Info.plist` (`LSUIElement`, `NSAllowsLocalNetworking`), generates `AppIcon.icns`.
- **Signing:** **Apple Development identity** (Xcode dev cert), auto-detected via `security find-identity -v -p codesigning | grep "Apple Development"`. No hardened-runtime/notarization in v1. README documents self-signing for other users.

## 7. Testing & QA gate

### 7.1 Zig (`zig build test`)
- JSON command parse / event serialize round-trips.
- Readiness-line matcher (positive/negative/edge: partial lines, different ports).
- curl `--progress-meter` parser (percent extraction, CR-delimited chunks, no-total case).
- Variant → script-arg + gguf-filename mapping (incl. RAM tiers).
- State-machine transitions, including illegal-command rejection.

### 7.2 Swift (`swift test`)
- Collector parsing on synthetic inputs (memory math, percent clamping, severity thresholds).
- RAM → default-variant logic; variant sizing table.
- Event JSON decoding (all event kinds, malformed-line resilience).
- Settings persistence/validation (ctx ≥ 1, Think-Max badge boundary at 393216).

### 7.3 Integration
- **Fake `ds4-server`** stub script: prints `listening on http://127.0.0.1:<port>`, serves a minimal `/v1/models`. Lets `ds4ctl` supervision be exercised end-to-end (start→ready→health→stop, crash detection) **without** the 430 GB model.
- **Fake `download_model.sh`** stub: emits synthetic curl-style progress for parser/event tests.

### 7.4 CI gate (GitHub Actions, macOS runner) — merge blocked on any failure
- `zig fmt --check` + `swift-format --lint` (formatting enforced).
- **Zero compiler warnings** (Zig + Swift).
- Release build of `ds4ctl` and the Swift app.
- `zig build test` + `swift test` green.
- App-bundle assembly + smoke launch (`--version`/headless sanity).

## 8. Repo polish

- **README:** what/why, screenshots/GIF, prerequisites (built `ds4`, a downloaded model), build, run, signing notes, troubleshooting.
- **LICENSE** + **attribution:** credit `mac-resource-monitor` and, transitively, `macmon` (MIT) for the IOReport approach.
- **CHANGELOG.md** (CalVer `YY.M.N`).
- **.gitignore** (`.build/`, `zig-out/`, `zig-cache/`, `*.app`, `gguf/`).
- CI badge.

## 9. Success criteria
1. From a clean menu-bar launch: pick Pro (auto-default on 512 GB), Start, see icon go orange→green, and watch memory climb to the resident set, all without touching a terminal.
2. Stop returns cleanly to idle (graceful SIGTERM).
3. Selecting an undownloaded variant offers Download with live progress, delegated to `download_model.sh`.
4. Mini widgets refresh at 2 s and read plausibly against `mac-resource-monitor`.
5. `zig build test`, `swift test`, formatting, and zero-warning release builds all pass in CI.

## 10. Open questions
None outstanding. (Name, metric set, default ctx = 393216/Think-Max, external ds4-dir all resolved with the user.)
