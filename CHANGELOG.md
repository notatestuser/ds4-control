# Changelog

## Unreleased
- Fix: after an unexpected ds4-server exit (typically a bind conflict with an orphaned server that owns the port), adopt the healthy port-holder as ready instead of dead-ending in an error whose Retry could only fail the same way again.
- Fix: settings/chat windows could open unfocused (greyed controls) right after an app restart — the one-shot activate was dropped while the activation-policy transition was in flight; window opening now retries activation until the window is key (bounded ~1 s).
- Settings: new "Concurrent sessions" slider (1–16, default 1) above "GPU power duty". Above 1 it passes ds4's `--batched-session N`, so that many chats/coding agents can generate at the same time; ds4 preallocates one resident KV session per slot at launch, so memory grows with sessions × context size. 1 omits the flag entirely, keeping the original single-session path.
- Settings copy pass: every footer/help text rewritten for clarity and plain wording (bind host, context hint, Disk KV cache, restart, thinking, Flash variant, downloads, cleanup dialog).
- Thinking is now a three-mode **Thinking:** control (Instant / Standard / Max Think, default Standard) shared by Settings and the chat status bar. Instant answers with no thinking; Standard thinks at any context size; choosing Max Think below a 393,216 context prompts to bump the context — and restarts a running server so it takes effect immediately. (Migrates the old Max Think toggle: off → Instant, on → Max Think.)
- ds4 submodule bumped 477c0e8 → 54b36ed: Metal prefill/decode kernel optimizations, native Metal session batching, SSD-streaming and server JSON fixes (113 commits).
- V4 Flash now runs the DeepSeek-V4-Flash-0731 weights (antirez's official `-0731` GGUFs; same q2 / q2-q4 / q4 recipes and sizes, so RAM tiers and context defaults are unchanged). V4 Pro is unchanged — no 0731 Pro release.
- One-time migration prompt: on first launch the popup offers to delete orphaned pre-0731 Flash GGUFs (~81–165 GiB each), including download partials, behind a confirmation that lists the exact files.
- Settings: the V4 Flash "Quant" picker is now "Variant", with each option marked by generation (e.g. `0731-q2-q4-imatrix`).
- Known caveat (upstream, antirez/ds4#635): with 0731 weights, ds4's `reasoning_effort=max` currently injects the prefix DeepSeek labels "high" — the official 0731 "max" prefix ("Reasoning Effort: Beyond maximum…") doesn't exist in ds4 yet. Think Max requests automatically become true 0731-max once ds4 adds it; no app change needed.

## v1.0.0 — 2026-06-02
- Initial release: DS4 Control — a macOS menu-bar control pane for ds4 (DeepSeek V4 Pro/Flash).
- Self-contained: ds4 (server + Metal shaders + downloader) bundled in the app; signed with a Developer ID certificate and notarized for Gatekeeper.
- Built-in streaming chat with Markdown rendering and stick-to-bottom autoscroll.
- Start/stop/monitor the local ds4-server; Pro/Flash selection (Pro default on ≥512 GiB RAM).
- Model downloads delegated to ds4's download_model.sh with live progress.
- Mini resource widgets: unified memory (hero), GPU, power/ANE, CPU.
- RAM-tiered default context with Think-Max (≥393216); budget-derived for lower-RAM machines.
