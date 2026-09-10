# Server Token-Speed Widget — Design

**Date:** 2026-08-12

## Goal

Show the live token-generation speed of the local `ds4-server` in the menu-bar
popup as a compact widget — covering the built-in chat **and** coding agents,
since the data comes from the server's own logs, not client measurement.

## How it works

`ds4-server` already prints per-request timing to stderr (the same stream the
supervisor tails for readiness detection):

```
ds4-server: chat ctx=0..52:52 prefill chunk 52/52 (100.0%) chunk=0.00 t/s avg=67.91 t/s 0.766s
ds4-server: chat ctx=52..57:5 gen=5 decoding chunk=41.40 t/s avg=41.40 t/s 0.121s
ds4-server: chat ctx=0..52:52 gen=5 finish=stop 0.887s
```

`ServerSpeedParser` (a pure type, sibling of `ReadinessMatcher`) extracts:
- `prefill … avg=X t/s` → prefill rate
- `gen=N decoding … avg=Y t/s` → decode rate + token count
- `gen=N finish=stop` → idle

The MTP `decode batch count=…` lines are deliberately ignored — they interleave
requests across concurrent sessions; the per-request lines are the clean signal.

`SupervisorService` publishes `serverSpeed` (phase/tps/tokens) and a capped
rolling `serverSpeedHistory` (last 60 (timestamp, tok/s) samples) from
`handleStderr`, reset on start/stop. The popup's "Server" card renders the
current rate with a sparkline.

## Scope / limitations

- It's a **"last request's speed"** gauge (decays to idle on `finish=`), not a
  live per-token ticker mid-generation — that would need client-side chat
  measurement.
- No server API changes; the data source is the existing stderr stream.

## Files

- `Services/ServerSpeedParser.swift` (new) — pure parser
- `Services/SupervisorService.swift` — published `serverSpeed` / `serverSpeedHistory`
- `Views/PopupView.swift` — the "Server" card
- Tests: `ServerSpeedParserTests.swift`, supervisor feed/cap/reset tests, popup source test
