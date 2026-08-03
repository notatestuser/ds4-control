# Changelog

## Unreleased

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
