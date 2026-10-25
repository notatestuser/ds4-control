# DS4 Control

[![CI](https://github.com/notatestuser/ds4-control/actions/workflows/ci.yml/badge.svg)](https://github.com/notatestuser/ds4-control/actions/workflows/ci.yml)

A macOS menu bar pane for **DeepSeek V4** and **V4.1** via [`dwarfstar`](https://github.com/antirez/ds4).

It launches, supervises, and monitors a local ds4 server, lets you pick **V4.1 Flash 1017**, **V4 Pro (0813)**, or **V4 Flash (0731)** with up to **1M** context, and shows resource use.

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
| V4.1 Flash 1017 | 1017-q2 | ≥ 96 GiB | 341 GiB on disk, ~152 GiB resident main weights + ~189 GiB disk-only Engram. SSD streaming engages automatically when the resident configuration does not fit (usually 96–255 GiB; slow: routed experts stream from disk). |
| V4.1 Flash 1017 | 1017-mxfp4 | ≥ 256 GiB | 467 GiB on disk, ~278 GiB resident main weights + ~189 GiB disk-only Engram. Streams on lower tiers; fully resident when the context, sessions, and live Metal wired limit permit it. |
| V4 Flash (0731) | q4-imatrix | ≥ 256 GiB | Standard. |
| V4 Flash (0731) | q2-imatrix | 96 GiB minimum | 96–127 GiB requires raising the Metal wired limit (see in-app help). |

V4.1 defaults to Q2 below 512 GiB and MXFP4 from 512 GiB. Its automatic context is 32,768 below the full-residency RAM tiers (Q2 below 256 GiB and MXFP4 below 384 GiB), and 1,048,576 at or above them. Whether a launch uses SSD streaming also depends on the live Metal wired limit. The launch gate accounts for each configured chat/agent session and ds4's host-memory budget, so the minimum tier alone does not guarantee every context/session combination fits. Engram stays on disk in both modes.

## V4.1 Flash 1017 downloads and migration

The 1017 recipes are pinned to [Hugging Face revision `9dcee516`](https://huggingface.co/antirez/deepseek-v4.1-flash-gguf/tree/9dcee51692e6540f697141fc98b097e3c96492a3): Q2 downloads one verified GGUF; MXFP4 downloads nine standard GGUF shards and assembles them natively into one file. The shards contain independent headers and tensor offsets, so they are parsed and rewritten rather than concatenated. Each shard is SHA-256 verified and removed only after its tensors and a durable assembly checkpoint are saved. Interrupted downloads and assembly resume after restart. MXFP4's incremental assembly needs about **562 GiB peak disk space plus 1 GiB headroom**; the finished file uses about 467 GiB. No Python installation is needed.

An existing V4.1 Q2 choice stays Q2; the former V4.1 Q4 choice becomes 1017 MXFP4. Other model selections and server/chat preferences are preserved. Earlier V4.1 weights are never renamed or treated as 1017 downloads, and the new weights use separate, quant-specific KV cache directories.

The popup detects obsolete V4.1 GGUFs, download sidecars, and the old `kv-flash-41` cache and offers a cleanup review while the server is stopped. A native confirmation lists the exact paths and estimated space before anything is deleted; Cancel is the default. **Not now** hides that banner, and **Settings → Downloads → Clean up old V4.1 data…** remains available. Current 1017 files and unrelated Hugging Face cache entries are kept. Failed deletions remain visible for retry.

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

The bundled runtime is pinned to [antirez/ds4 `a1012463383a`](https://github.com/antirez/ds4/commit/a1012463383a09c6d11f8164218e0ee45e267acf). The app's V4.1 allocation/admission mirror is checked against that source. The manual memory harness can exercise either 1017 quant in streaming or resident mode; it is separate from the unit tests and does load the real weights:

```sh
# Q2 streaming frontier run on a 128 GiB host.
DS41_LIMIT_GIB=128 scripts/flash41-mem-harness.sh "32768"
# Short resident MXFP4 smoke run on a suitably sized host.
DS41_QUANT=mxfp4 DS41_MODE=resident DS41_LIMIT_GIB=512 \
  DS41_PROMPT_TOKENS=64 DS41_SKIP_CONTROL=1 scripts/flash41-mem-harness.sh "32768"
```

These commands are validation procedures, not a claim that this release has been tested with real 1017 weights on every memory tier. A short smoke prefill does not validate the frontier-memory peak.

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
