# Changelog

## Unreleased
- ds4 submodule bumped 54b36ed → upstream `84cc882` (118 commits), with our THINK_MAX patch rebased on top (`ds4-control-patches-v2`). Highlights:
  - **Correctness, and it applied to us.** `metal: fix long-context prefill and decode correctness` fixes a missing device-memory barrier in the RoPE helper (`mem_threadgroup` → `mem_device_and_threadgroup`; it writes device memory other lanes read, so a threadgroup-only fence left a race), and disables a non-reproducible streaming top-k selector whose trigger — `top_k == 512 && n_comp > 1024 && n_tokens >= 32` — is exactly V4 Flash's `index_topk: 512` on long-context prefill.
  - **Decode is measurably faster on Apple Silicon.** Upstream's "exact" fusion campaign (bit-identical A/B verified across 134.6M F32 logits) reports M3 Ultra 41.08 → 44.18 tok/s. Measured here on q4-imatrix with an identical 400-token greedy prompt: **34.85 → 40.07 tok/s (+15%)**.
  - **MXFP4 routed experts are now supported** (`DS4_TENSOR_MXFP4` in `tensor_is_routed_expert_type`, 179 mentions in `metal/moe.metal`), so upstream's `ds4f-mxfp4` build (~156 GB) becomes runnable. Not yet offered in the app.
  - Prefill acceleration (routed MoE, indexed, Metal 4 Q4 attention output, Q-head norm + RoPE fusion), streamed-expert mlock pinning restored, and ~8 DSpark commits including `Restore greedy identity after DSpark acceptance` and `Make DSpark scheduling deterministic by default`.
  - `download_model.sh` gains the renamed `ds4f-*` targets (`ds4f-q2`, `ds4f-q2-q4`, `ds4f-q4`, `ds4f-mxfp4`, `ds4f-dspark`). These resolve to the *same* `-0731` files the app already downloads natively, so nothing in the app changes.
  - Note: ds4's default DSpark confidence threshold moved from 0.9 to Metal 0.6 / CUDA-ROCm 0.7.

## v1.1.0 — 2026-08-03
- Fix: after an unexpected ds4-server exit (typically a bind conflict with an orphaned server that owns the port), adopt the healthy port-holder as ready instead of dead-ending in an error whose Retry could only fail the same way again.
- Fix: Apply & Restart on an attached (previously orphaned) server relaunched the moment SIGTERM was *sent*, while the old process was still dying — ds4 refuses a second instance ("another ds4 process is already running") and the new server exited on startup. Attached stops now wait for the old pids to actually exit (SIGKILL after 30 s grace) before going idle and relaunching.
- Fix: settings/chat windows could open unfocused (greyed controls) after an app restart — activation is now requested inside the menu-bar click's user-event context (deferred activates are dropped for background-launched processes), with a bounded retry-until-key as backstop.
- Settings: new "Concurrent sessions" slider (1–16, default 1) above "GPU power duty". Above 1 it passes ds4's `--batched-session N`, so that many chats/coding agents can generate at the same time; ds4 preallocates one resident KV session per slot at launch, so memory grows with sessions × context size. 1 omits the flag entirely, keeping the original single-session path.
- Settings copy pass: every footer/help text rewritten for clarity and plain wording (bind host, context hint, Disk KV cache, restart, thinking, Flash variant, downloads, cleanup dialog).
- Thinking is now a three-mode **Thinking:** control (Instant / Standard / Max Think, default Standard) shared by Settings and the chat status bar. Instant answers with no thinking; Standard thinks at any context size; choosing Max Think below a 393,216 context prompts to bump the context — and restarts a running server so it takes effect immediately. (Migrates the old Max Think toggle: off → Instant, on → Max Think.)
- ds4 submodule bumped 477c0e8 → 54b36ed: Metal prefill/decode kernel optimizations, native Metal session batching, SSD-streaming and server JSON fixes (113 commits).
- V4 Flash now runs the DeepSeek-V4-Flash-0731 weights (antirez's official `-0731` GGUFs; same q2 / q2-q4 / q4 recipes and sizes, so RAM tiers and context defaults are unchanged). V4 Pro is unchanged — no 0731 Pro release.
- One-time migration prompt: on first launch the popup offers to delete orphaned pre-0731 Flash GGUFs (~81–165 GiB each), including download partials, behind a confirmation that lists the exact files.
- Settings: the V4 Flash "Quant" picker is now "Variant", with each option marked by generation (e.g. `0731-q2-q4-imatrix`).
- ds4 think-tier fix (our patch on the fork `notatestuser/ds4`, branch `ds4-control-patches`): THINK_MAX now emits the official 0731 "max" prefix ("Reasoning Effort: Beyond maximum…") instead of the 0731 "high" one, so Max Think is true 0731-max. THINK_HIGH stays prefix-less (DeepSeek's default low tier), so Standard is unchanged. The ds4 submodule points at the fork until antirez lands the same fix upstream (antirez/ds4#635) — then flip `.gitmodules` back or fast-forward the fork.

## v1.0.0 — 2026-06-02
- Initial release: DS4 Control — a macOS menu-bar control pane for ds4 (DeepSeek V4 Pro/Flash).
- Self-contained: ds4 (server + Metal shaders + downloader) bundled in the app; signed with a Developer ID certificate and notarized for Gatekeeper.
- Built-in streaming chat with Markdown rendering and stick-to-bottom autoscroll.
- Start/stop/monitor the local ds4-server; Pro/Flash selection (Pro default on ≥512 GiB RAM).
- Model downloads delegated to ds4's download_model.sh with live progress.
- Mini resource widgets: unified memory (hero), GPU, power/ANE, CPU.
- RAM-tiered default context with Think-Max (≥393216); budget-derived for lower-RAM machines.
