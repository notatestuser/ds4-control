# Changelog

## Unreleased
- ds4 submodule bumped 477c0e8 → 54b36ed: Metal prefill/decode kernel optimizations, native Metal session batching, SSD-streaming and server JSON fixes (113 commits).
- V4 Flash now runs the DeepSeek-V4-Flash-0731 weights (antirez's official `-0731` GGUFs; same q2 / q2-q4 / q4 recipes and sizes, so RAM tiers and context defaults are unchanged). V4 Pro is unchanged — no 0731 Pro release.
- One-time migration prompt: on first launch the popup offers to delete orphaned pre-0731 Flash GGUFs (~81–165 GiB each), including download partials.
- Known caveat (upstream, antirez/ds4#635): with 0731 weights, ds4's `reasoning_effort=max` currently injects the prefix DeepSeek labels "high" — the official 0731 "max" prefix ("Reasoning Effort: Beyond maximum…") doesn't exist in ds4 yet. Think Max requests automatically become true 0731-max once ds4 adds it; no app change needed.

## v1.0.0 — 2026-06-02
- Initial release: DS4 Control — a macOS menu-bar control pane for ds4 (DeepSeek V4 Pro/Flash).
- Self-contained: ds4 (server + Metal shaders + downloader) bundled in the app; signed with a Developer ID certificate and notarized for Gatekeeper.
- Built-in streaming chat with Markdown rendering and stick-to-bottom autoscroll.
- Start/stop/monitor the local ds4-server; Pro/Flash selection (Pro default on ≥512 GiB RAM).
- Model downloads delegated to ds4's download_model.sh with live progress.
- Mini resource widgets: unified memory (hero), GPU, power/ANE, CPU.
- RAM-tiered default context with Think-Max (≥393216); budget-derived for lower-RAM machines.
