# DS4 Control

[![CI](https://github.com/notatestuser/ds4-control/actions/workflows/ci.yml/badge.svg)](https://github.com/notatestuser/ds4-control/actions/workflows/ci.yml)

A macOS menu bar pane for **DeepSeek V4** via [`dwarfstar4`](https://github.com/antirez/ds4).

It launches, supervises, and monitors a local ds4 server, lets you pick **V4 Pro** or **V4 Flash (0731)** with up to **1M** context, and shows resource use.

**Launch Pi, Claude Code or BYOC (Bring Your Own CLI) for local agentic coding.**

<br>

<p align="center">
  <img alt="DS4 Control menu-bar popup: the V4 Pro/Flash selector, a Unified Memory hero gauge, GPU, CPU and power widgets, and gear/chat/terminal shortcuts" src="docs/screenshot-full-light-v4.png#gh-light-mode-only">
  <img alt="DS4 Control menu-bar popup: the V4 Pro/Flash selector, a Unified Memory hero gauge, GPU, CPU and power widgets, and gear/chat/terminal shortcuts" src="docs/screenshot-dark-v8.png#gh-dark-mode-only" width="380">
</p>

<p align="center">
  <a href="https://github.com/notatestuser/ds4-control/releases/latest">
    <img src="https://img.shields.io/badge/Download-DS4%20Control%20for%20macOS%20(.dmg)-1f6feb?style=for-the-badge&logo=apple&logoColor=white" alt="Download the latest DS4 Control .dmg for macOS" height="46">
  </a>
  <a href="https://formulae.brew.sh/cask/ds4-control">
    <img src="https://img.shields.io/homebrew/cask/v/ds4-control?style=for-the-badge&logo=homebrew&logoColor=white&color=4270e4" alt="Install DS4 Control Cask via Homebrew" height="46">
  </a>
</p>

<p align="center">
  <b>Signed with a live Apple Developer ID &amp; notarized by Apple</b>
</p>

## What it does

- **Start / stop / monitor** the local `ds4-server` child process — spawn, stderr readiness detection, health polling, graceful stop, and crash detection.
- **Pro / Flash selector** with a RAM feasibility gate.
- **Model downloads** via a built-in native parallel downloader, with a live progress bar and resume across restarts.
- **Mini resource widgets**: unified memory, GPU, power, and CPU, sampled on a timer.
- **Launch Chat** to talk to the model.
- **Launch Claude Code or Pi** to plan, write, maintain or refactor code.
- **1M Context** configurable in settings.

What it is **not**:

- No model search or registry browsing.
- No embedded inference — all inference is delegated to `ds4-server`.

## Dev quick start

[antirez/ds4](https://github.com/antirez/ds4) is vendored as a git submodule at `external/ds4`:

```sh
git submodule update --init --recursive    # fetch ds4 into external/ds4
make -C external/ds4 -j ds4-server          # build the ds4-server binary
DS4_DIR="$PWD/external/ds4" swift run        # build + run the dev app against the submodule
```

`DS4_DIR` points the app at that ds4 checkout so **Start** can spawn `ds4-server` — without it the dev build looks for a bundled `ds4/` next to the binary and won't find the server. It's a menu-bar app (no dock icon): after launch, click the bolt icon in the macOS menu bar, pick **Pro** or **Flash** (preselected by your RAM), then **Download** (if the model isn't present) and **Start**.

## Requirements

- **Apple Silicon**
- You don't pre-download the model — DS4 Control downloads it for you with a built-in parallel downloader, resumable across restarts.
- **Auth (optional):** the model repository is public, so no token is required for normal use.
- **RAM** — see below.

## RAM feasibility

DeepSeek V4 is memory-hungry so DS4 Control gates feasibility before launching.

| Variant | Quant | RAM | Notes |
| --- | --- | --- | --- |
| V4 Pro | pro-imatrix | **≥ 512 GiB required** | Anything below is blocked. |
| V4 Flash (0731) | q4-imatrix | ≥ 256 GiB | Standard. |
| V4 Flash (0731) | q2-imatrix | 96 GiB minimum | 96–127 GiB requires raising the Metal wired limit (see below). |

On any machine where the model's GPU-wired working set (the exact GGUF plus ds4's resident context, Metal graph allocations, and persistent backend scratch, including one prefill workspace and one indexer top-k scratch buffer shared across concurrent sessions) exceeds the **effective Metal wired limit**, Start is gated. Configurations that cannot fit while leaving ~4 GiB for macOS are blocked instead of being offered an unsafe wired-limit increase. The disk KV cache does not shrink this working set: ds4 preallocates every resident session's context, while disk caching only checkpoints those sessions for reuse after a slot switch or server restart. The effective limit is your `iogpu.wired_limit_mb` when raised, else the macOS default — a machine-specific fraction of RAM (~75–84% depending on macOS version) that DS4 Control queries from Metal rather than assumes. When gated, the popup shows the required fix:

```sh
sudo sysctl iogpu.wired_limit_mb=<value shown in the popup>
```

and a "Metal wired limit help…" window walks through it step by step — including making it survive reboots (the sysctl resets on every restart, which is why a setup that worked before can hang after one). A confirmed "Start anyway" override remains if you know your setup works. This applies most often to 96–127 GiB machines running Flash q2, but also to V4 Pro on 512 GiB and Flash q2-q4 at 1M context on 128 GiB when their default cap is below the working set.

**Default context** is `1,000,000` for Pro and for Flash on ≥ 128 GiB; Flash on 96–127 GiB defaults to `256,000`. Max Think is unavailable below 128 GiB, including in the built-in chat and coding-agent launcher. You can otherwise override the context in Settings, subject to the physical-memory and wired-limit checks above.

## Performance

Measured single-stream generation throughput on a **Mac Studio M3 Ultra** (512 GiB):

| Model | Throughput |
|---|---|
| V4 Pro | **~14 tok/s** |
| V4 Flash (0731) | **~35 tok/s** |

Varies with context length, prompt, and the Metal wired limit.

## Build & Run

For development:

```sh
swift run
```

To produce a distributable bundle:

```sh
bash build.sh
```

This builds a release binary and assembles `DS4 Control.app`.

**First run:** open **Settings** (the gear in the popup) and set the **ds4 directory** — the folder that contains `ds4-server`.

## Signing

`build.sh` auto-detects your **Apple Development** identity via `security find-identity` and signs the bundle with it. If no Apple Development identity is installed, it falls back to **ad-hoc** signing (the app runs locally but is not distributable).

To sign with your own key:

- Install an Apple Development certificate (Xcode → Settings → Accounts → Manage Certificates → **+** → Apple Development), **or**
- Set `DS4_SIGN_IDENTITY="Apple Development: …"` before running `build.sh`.

## How it works

DS4 Control is a single Swift binary — no embedded inference and no second process language. Three `@MainActor` objects do the work, and the SwiftUI layer just observes them:

- **`SupervisorService`** owns the `ds4-server` lifecycle through `Foundation.Process`: it builds the launch arguments, watches stderr for the `listening on http://` readiness line, polls `GET /v1/models` for health, and stops gracefully with SIGTERM (SIGKILL fallback). Model weights are fetched by a built-in native parallel downloader (resumable across restarts).
- **`MetricsManager`** samples CPU, memory, GPU, and power/ANE via Mach, IOKit, and the private IOReport interface every 2 s, publishing a `SystemSnapshot` to the widgets.
- **`Feasibility`** turns installed RAM into a variant choice and a budget-derived default context (pure, fully unit-tested).

The pieces with real logic — the feasibility/context math, the readiness parser, the resumable chunk/bitmap downloader, and the supervisor state machine — are pure and covered by tests. The supervisor is exercised end-to-end against a fake `ds4-server` and an injected download, so the full lifecycle is tested without downloading a multi-hundred-gigabyte model.

## Testing / QA

```sh
swift test
```

Tests cover the pure logic (variant/feasibility/context math, readiness parser, chunk-bitmap resume) plus model-free integration of the supervisor via a fake `ds4-server` and an injected download. No real model is needed.

CI (GitHub Actions, `macos-26`) runs, on every pull request:

- `swift format` lint (strict),
- a release build with warnings treated as errors,
- the test suite,
- a bundle smoke build (`build.sh`, ad-hoc signed in CI).

## Attribution

- The resource collectors and widgets are adapted from **mac-resource-monitor**, which in turn credits **[macmon](https://github.com/vladkens/macmon)** (MIT) for the IOReport power-sampling approach.
- The server-supervision pattern is built on the lineage of **mlx-serve**.

## License

MIT — see [LICENSE](LICENSE).
