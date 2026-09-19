# DS4 Control

[![CI](https://github.com/notatestuser/ds4-control/actions/workflows/ci.yml/badge.svg)](https://github.com/notatestuser/ds4-control/actions/workflows/ci.yml)

A macOS menu bar pane for **DeepSeek V4** and **V4.1** via [`dwarfstar`](https://github.com/antirez/ds4).

It launches, supervises, and monitors a local ds4 server, lets you pick **V4.1 Flash**, **V4 Pro (0813)**, or **V4 Flash (0731)** with up to **1M** context, and shows resource use.

**Launch Pi, Claude Code or [BYOC](https://github.com/antirez/ds4/blob/main/docs/CLIENTS.md) (Bring Your Own CLI) for local agentic coding.**

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

## Quick Install

```bash
brew install --cask ds4-control
```

## Features

- **Start / stop / monitor** the local `ds4-server` child process — spawn, stderr readiness detection, health polling, graceful stop, and crash detection.
- **Pro / Flash selector** with a RAM feasibility checks.
- **Model downloads** via a built-in native parallel downloader, with a live progress bar and resume across restarts.
- **Mini resource widgets**: unified memory, GPU, power, and CPU, sampled on a timer.
- **Launch Chat** to talk to the model.
- **Launch Claude Code or Pi** to plan, write, maintain or refactor code.
- **1M Context** configurable in settings.
- **Launch on macOS Startup**

What it is **not**:

- No model search or registry browsing.
- No embedded inference — all inference is delegated to `ds4-server`.

## Dev quick start

[antirez/ds4](https://github.com/antirez/ds4) is vendored as a git submodule at `external/ds4`:

```sh
git submodule update --init --recursive    # fetch ds4 into external/ds4
bash scripts/apply-ds4-patches.sh           # THINK_MAX prefix (antirez/ds4#635)
make -C external/ds4 -j ds4-server          # build the ds4-server binary
DS4_DIR="$PWD/external/ds4" swift run        # build + run the dev app against the submodule
```

## Requirements

- **Apple Silicon**
- You don't pre-download the model — DS4 Control downloads it for you with a built-in parallel downloader, resumable across restarts.
- **Auth (optional):** the model repository is public, so no token is required for normal use.
- **RAM** — see below.

## RAM feasibility

DeepSeek V4 is memory-hungry so DS4 Control gates feasibility before launching.

| Variant | Quant | RAM | Notes |
| --- | --- | --- | --- |
| V4 Pro (0813) | pro-imatrix | **≥ 512 GiB required** | Anything below is blocked. |
| V4.1 Flash | 41-q2 | ≥ 96 GiB | 341 GiB on disk, ~152 GiB resident main weights + ~189 GiB disk-only Engram. SSD streaming engages automatically on 96–255 GiB (slow: nearly every routed expert streams from disk); full residency on ≥ 256 GiB. |
| V4.1 Flash | 41-q4 | ≥ 256 GiB | 483 GiB on disk, ~294 GiB resident main weights. SSD streaming on 256–511 GiB; full residency on ≥ 512 GiB. |
| V4 Flash (0731) | q4-imatrix | ≥ 256 GiB | Standard. |
| V4 Flash (0731) | q2-imatrix | 96 GiB minimum | 96–127 GiB requires raising the Metal wired limit (see in-app help). |

## Performance

Measured single-stream generation throughput on a **Mac Studio M3 Ultra** (512 GiB):

| Model | Throughput |
|---|---|
| V4 Pro (0813) | **~14 tok/s** |
| V4 Flash (0731) | **~35 tok/s** |

Varies with context length, prompt, and the Metal wired limit.

## Coding Agents

It’s suggested to follow the ds4 [coding agent setup guide](https://github.com/antirez/ds4/blob/main/docs/CLIENTS.md) to configure your OpenCode/Claude/Codex/Pi as you prefer.

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

## Attribution

- A big thanks of course to @antirez for antirez/ds4, llama.c and GGML for instrumental foundational work.
- The resource collectors and widgets are adapted from **mac-resource-monitor**, which in turn credits **[macmon](https://github.com/vladkens/macmon)** (MIT) for the IOReport power-sampling approach.
- The server-supervision pattern is built on the lineage of **mlx-serve**.

## License

MIT — see [LICENSE](LICENSE).
