# Chat renderer: replace NSTextView with Textual + incremental block streaming

- **Date:** 2026-06-03
- **Status:** Approved design — pending spec review
- **Branch:** `feat/chat-textual-renderer`
- **Drivers (user-selected):** kill the chat-freeze permanently · cut maintenance · open to alternatives (explicitly *not* UX modernization)

## Summary

Replace the custom NSTextView-based markdown renderer in `Sources/DS4Control/Views/MarkdownText.swift`
(~693 lines: `MarkdownText` + `SelectableMarkdownNSText` + `IntrinsicTextView`) with the **Textual**
SwiftUI text-rendering package, behind a one-file seam. Finished message bubbles render as a single
`StructuredText`; the in-flight streaming bubble renders **block-split** — completed markdown blocks
frozen with stable identity, only the trailing block re-parsing per streaming tick. The rest of the
chat stack (ChatService, SSE parser, thinking disclosure, stats, windowing, wiring) is unchanged;
`ChatViewModel`'s flush loop is extended for update scheduling (below) but its public surface is not.

Two outcomes:
1. The documented freeze mechanism — an `NSView` whose height is a pure function of width feeding back
   into a greedy-width SwiftUI container — is removed by construction (pure SwiftUI, no NSView bridge).
2. Per-token cost on long replies is bounded to **O(trailing block)** by the incremental split, not
   O(message), with a single-in-flight guard providing adaptive backpressure.

## Background

### Current architecture (unchanged unless noted)
- `ChatView` → `ScrollView` + windowed `LazyVStack` (≤50 msgs) of `MessageBubble`, each `.id(message.id)`,
  with a "Show earlier" control.
- `MessageBubble` mixes `MarkdownText(message.content)` with SwiftUI chrome; `ThinkingDisclosure` shows
  `message.thinking`.
- `MarkdownText` wraps `SelectableMarkdownNSText` (`NSViewRepresentable`) backing `IntrinsicTextView`
  (an `NSTextView` whose `intrinsicContentSize` height = f(width), invalidated on `setFrameSize` /
  `didChangeText`).
- Streaming: `ChatService` (SSE) → `ChatViewModel` buffers deltas and flushes to `messages` every 33 ms;
  `content` and `reasoning_content` (→ `thinking`) are kept separate.

### The problem — two distinct failure modes
| Mode | Cause | Status today |
|---|---|---|
| **Layout non-convergence** ("chat freeze", 100% main-thread CPU) | `NSView` height = f(width) oscillates against greedy-width siblings; the layout pass never reaches a fixed point | Recurring; multiple partial fixes + one revert in git history → cause strongly suspected but **not proven** |
| **Reparse / re-eval per token** | Whole growing string re-parsed + view tree rebuilt each update | Latent today; would worsen with any naive renderer swap |

Switching renderers addresses Mode 1 only. Mode 2 needs an incremental update architecture, which is
**renderer-independent and owned by us**. The robust fix needs both.

## Decision

Adopt **Textual** (`gonzalezreal/textual`, MIT, v0.3.x) behind a one-file seam, with an incremental
block-streaming layer we own.

- Pure SwiftUI (SwiftUI `Text` pipeline + Foundation `AttributedString` parser) → eliminates the
  `NSView` self-sizing loop (Mode 1) by construction.
- Native text selection, themable (`.gitHub` / custom `StructuredText.Style`), tables/code/lists/math.
- Pre-1.0 reality: API may churn, and Textual has shown SwiftUI update-cascade hangs on long documents
  (a fork profiled ~1.8M SwiftUI updates / 543 ms hang on a long chat). Both are neutralized by (a) the
  one-file seam and (b) the block-split + single-in-flight design — finished blocks are static, only the
  tail updates, and never more than one update is outstanding.

**Rejected alternatives:** ConversationKit (iOS-first, no thinking section, replaces the whole UI);
MarkdownUI (maintenance mode, full reparse, weaker selection); lakr233 MarkdownView (reintroduces a
TextKit `NSView` bridge — the failure pattern we are leaving — plus 20★, heavy branch-pinned deps, and
a DIY/unproven macOS SwiftUI wrapper); roll-our-own (viable, but we would own table/code-highlight
quality).

### Cost: macOS deployment-floor bump
Textual requires macOS 15; the app currently targets macOS 14 (`Package.swift:6`). Bump
`.macOS(.v14)` → `.macOS(.v15)`. **Confirmed: macOS 15** (user is fine going as high as 26, but 15 is the
choice for widest compatibility). Dropping macOS 14 (Sonoma) users from new releases is accepted.

## Non-goals (YAGNI)
- No change to `ChatView` structure, the composer, `ChatService`, `ChatSSEParser`, stats, windowing,
  Max-Think, or app wiring. (`ChatViewModel`'s flush loop *is* extended — see Streaming update scheduling
  — for the thinking cadence + single-in-flight guard; its public surface is unchanged.)
- Not adopting ConversationKit or any full chat-UI framework.
- Not rendering LaTeX math yet — keep the `deLaTeXed` stripping. (Future option: enable Textual `.math`
  and drop the stripper.)
- No visual redesign; match the current feel with a light theme that tracks system appearance, not a
  pixel rebuild of the golden-ratio heading scale.

## Design

### Components
| Unit | File | Role | Imports `Textual`? |
|---|---|---|---|
| Block splitter | `Sources/DS4Control/Views/MarkdownBlocks.swift` (new) | Pure `splitBlocks(_:) -> (completed: [String], tail: String)`, fence-aware boundary detection. Dependency-free, unit-tested. | No |
| Renderer seam | `Sources/DS4Control/Views/MarkdownText.swift` (rewritten) | `MarkdownText(_:)` single-view render; `StreamingMarkdownText(_:)` block-split render; `preprocess(_:)` (LaTeX + tag strip); `Theme.ds4`. The **only** file importing `Textual`. | Yes (only here) |
| Bubble | `Sources/DS4Control/Views/ChatView.swift` (light edits) | `MessageBubble` / `ThinkingDisclosure` choose single vs streaming render by `message.isStreaming`; thinking renders only when expanded; remove the now-unneeded `.fixedSize` / greedy-width workarounds. | No |
| Update scheduling | `Sources/DS4Control/ViewModels/ChatViewModel.swift` (flush-loop edits) | ~250 ms thinking cadence + MainActor single-in-flight guard; public surface unchanged. | No |

### Rendering granularity
The whole chat is **not** one Textual view. Granularity is per-message, and finer for the one streaming
message:

```
ScrollView
└─ LazyVStack (windowed ~50, each .id(message.id))
   ├─ MessageBubble (finished)  → StructuredText(whole message)   ← parsed once, static
   ├─ MessageBubble (finished)  → StructuredText(whole message)
   └─ MessageBubble (STREAMING) → VStack:
        ├─ StructuredText(block 1)   ← frozen, stable .id
        ├─ StructuredText(block 2)   ← frozen, stable .id
        └─ StructuredText(tail)      ← only this re-parses each tick
```

- **Finished message** (`isStreaming == false`): one `StructuredText(markdown: preprocess(content))` →
  correct inter-block spacing, whole-message selection, parsed once, never re-evaluated while later
  messages stream.
- **Streaming message** (`isStreaming == true`): `StreamingMarkdownText` renders
  `splitBlocks(preprocess(content))` as a `VStack` — each completed block a static `StructuredText`
  keyed by stable index `.id`; the trailing block a `StructuredText` that re-parses each tick.
  Per-tick cost = O(tail).
- **On finalize**: the bubble flips to `isStreaming == false` → collapses to the single-view form (one
  extra parse, once) for clean spacing + selection.
- **Thinking** (decision A): single-view, **rendered only when the disclosure is expanded** — collapsed
  (the default) costs nothing; the string just accumulates in the model. Reuses `StreamingMarkdownText`,
  so upgrading thinking to block-split later (if you watch long reasoning live often) is a one-line swap.

### Streaming update scheduling (throttle + single-in-flight guard)
Lives in `ChatViewModel`'s flush loop (extends the existing 33 ms throttle). Three layers keep the
streaming bubble cheap and loop-proof:

- **Cadence:** content deltas flush every ~33 ms; thinking deltas every ~250 ms (one timer; thinking
  flushed on a sub-cadence — live-ness is not critical for reasoning).
- **Single-in-flight guard:** a MainActor `updateInFlight` flag. A flush tick that finds it set **skips**
  (deltas keep buffering); otherwise it sets the flag, applies the `@Published` mutation, and clears it
  on the next main-actor turn (post-mutation). This serializes updates with adaptive backpressure — if a
  parse/layout takes longer than the interval, ticks are skipped instead of piling a second heavy update
  onto an unsettled one. Applies to **both** content and thinking.
- **Trailing guarantee:** deltas are never lost — they accumulate while skipped, and `finish()` /
  `stop()` force a final synchronous flush.
- *SwiftUI caveat:* there is no literal "render finished" callback, so the flag clears on the next
  main-actor runloop turn — a safe serialization boundary, not a precise completion signal. (Textual
  exposes no pre-parsed/`AttributedString` entry point in current docs, so an off-main parse-task signal
  is not available; not required for correctness.)

### `splitBlocks` contract
- Input: a markdown string (post-`preprocess`). Output `(completed: [String], tail: String)` with the
  invariant `completed.joined() + tail == input`.
- Boundary = a blank line (`\n\n`) at fence-depth 0. Track ```` ``` ```` / `~~~` open/close; blank lines
  inside an open fence are **not** boundaries.
- If a code fence is currently open, the entire open block stays in `tail` until its closing fence
  arrives.
- `tail` = everything after the last depth-0 boundary (the mutable region); `completed` = the stabilized
  prefix blocks.
- Conservative: when in doubt, keep content in `tail` (re-render) rather than freezing it incorrectly.

### Theme & selection
- Base on Textual's `.gitHub` preset; small `Theme.ds4` (`StructuredText.Style`) override for bubble fit
  (body font/size, code-block background matching app surfaces, link color, block spacing).
- **System appearance (light/dark) tracked automatically.** `Theme.ds4` derives all colors from system
  semantic colors (SwiftUI `.primary`/`.secondary`, `NSColor.textColor`/`.secondaryLabelColor`/
  `.textBackgroundColor`/`.controlBackgroundColor`), never fixed RGB, so Textual adapts via SwiftUI's
  `colorScheme`. No manual toggle. Verify rendering in both light and dark.
- Tune block spacing so the streaming split view and the finished single view render **identically**
  (no finalize "settle").
- `.textual.textSelection(.enabled)` on bubbles → native selection + copy.

### Preprocessing (retained, renderer-agnostic)
- `deLaTeXed`: strip `\[ \] \( \) $$`, map `\boxed{}` → `**…**`, `\frac{a}{b}` → `a/b`, plus the symbol
  table. Output is plain markdown Textual renders directly.
- Strip/hide `<tool_call>` (and the legacy inline `<thinking>` / `<think>` tags) so they do not render in
  answer content. Reasoning arrives via `reasoning_content` → `thinking` and renders in the disclosure.

### Dependency & build
- `Package.swift`: add `.package(url: "https://github.com/gonzalezreal/textual", from: "<pin latest at
  implementation time — do not hardcode here>")`; add product `Textual` to the `DS4Control` target.
  Transitive deps: swift-concurrency-extras, swiftui-math, a bundled Prism highlighter resource.
- Bump platform to `.macOS(.v15)`. swift-tools 6.3 + Swift 6 mode already satisfy Textual (tools 6.0).
- Update CI (`.github/workflows/ci.yml`) and release (`release.yml`) macOS runner / SDK expectations to
  macOS 15.

## Risks & mitigations
| Risk | Mitigation |
|---|---|
| Textual pre-1.0 API churn | One-file seam (`MarkdownText.swift`); swapping renderer later = one file + `Package.swift` |
| Textual update-cascade on long docs | Block-split (finished blocks static, stable `.id`) + single-in-flight guard; only the tail re-evaluates. Validated by the stress test. |
| Render slower than the flush interval piling up (death loop) | Single-in-flight guard skips ticks while an update is outstanding (adaptive backpressure) |
| Long *open* code block re-parses each tick (large tail) | Render the open fence as plain monospaced tail; full syntax highlight on close. Accept O(open-block) until closed. |
| Finalize spacing "settle" between split and single view | Tune `Theme.ds4` spacing so split and single render identically |
| Selection across blocks while streaming | Acceptable (streaming is transient); the finished message is a single view → full selection |
| Dropping macOS 14 users | Accepted by user; floor 15 |
| Freeze cause not fully proven | Step 0 (below) confirms it empirically *before* relying on the fix |

## Verification plan
1. **Step 0 — confirm the cause + baseline (before coding).** Reproduce the freeze on the current build
   with a long reply (real ds4-server, or inject a long assistant transcript), capture
   `/usr/bin/sample <pid> 3 -file /tmp/freeze-before.txt`, and confirm the spinning stack is SwiftUI
   layout ↔ `IntrinsicTextView` sizing. Record as the before-baseline. This converts "suspected cause"
   into "known cause" and proves the NSView bridge is what we are removing.
2. **Build/test gate.** `swift build && swift test` green (authoritative — SourceKit diagnostics here are
   often stale).
3. **Acceptance — long-reply stress (manual, measured).** Stream an 8–10k-token reply mixing prose,
   multiple code blocks, a table, and lists. Pass = main thread responsive, smooth scroll, no runaway CPU
   in `sample`/Instruments, no freeze. Compare against the Step 0 baseline. Confirm a render slower than
   the flush interval **skips** ticks rather than piling up (guard holds).
4. **Smoke.** Thinking disclosure expand/collapse during and after stream (collapsed = no render cost);
   code/table/list rendering; a LaTeX-bearing reply renders cleanly (stripped); select + copy from a
   finished bubble; transcript windowing + "Show earlier"; render correctly in **both light and dark**.

## Testing strategy
- **Keep:** `deLaTeXed` / preprocess tests; all `ChatViewModelTests`, `ChatServiceTests`,
  `ChatSSEParserTests` (stream untouched), including the uncommitted `testFinishFlushesBufferSynchronously`.
- **Add (renderer):** `MarkdownBlocksTests` — `splitBlocks` boundaries (blank line at depth 0,
  open/closed fences, open-fence-stays-in-tail, the `completed.joined() + tail == input` invariant);
  `preprocess` tests (LaTeX mapping, `<tool_call>` strip).
- **Add (ViewModel):** flush-guard tests — a tick while `updateInFlight` skips (no extra mutation);
  buffered deltas still land via the trailing flush (no loss); thinking flushes on the coarser ~250 ms
  cadence while content flushes at ~33 ms.
- **Remove (internals deleted):** `MarkdownTextTests` cases for `attributedString(for:)` extraction, the
  heading golden-ratio scale, and the append-only / placeholder guard
  (`testPlaceholderToContentPreservesFirstCharacter`, `testStreamingAppendPreservesDelta`).
- The streaming **perf gate is manual** (`sample` / Instruments), not a unit test — stated explicitly so
  it is not silently dropped.

## Working-tree changes (handle first)
- `ChatViewModel.swift` (+82, the 33 ms throttle) and `ChatViewModelTests.swift` (+15): **keep** —
  renderer-independent; land as a standalone commit before the swap. The scheduling work (thinking
  cadence + guard) extends this.
- `MarkdownText.swift` (+10, placeholder guard) and `MarkdownTextTests.swift` (+32): **superseded** —
  deleted by the rewrite.

## Rollback
Revert `MarkdownText.swift`, delete `MarkdownBlocks.swift`, drop the Textual dependency + macOS-floor
bump in `Package.swift`, and revert the `MessageBubble` / `ThinkingDisclosure` + `ChatViewModel`
scheduling edits. The seam keeps this to ~4 files.

## Implementation outline (detail deferred to writing-plans)
1. Commit the pending VM throttle work (isolate it from the swap).
2. Step 0: freeze repro + `sample` baseline.
3. Add the Textual dependency + bump the macOS floor; `swift build`.
4. `MarkdownBlocks.swift` + `MarkdownBlocksTests` (`splitBlocks`).
5. Extend `ChatViewModel` flush loop: ~250 ms thinking cadence + MainActor single-in-flight guard + tests.
6. Rewrite `MarkdownText.swift`: `preprocess`, `MarkdownText` (single), `StreamingMarkdownText` (split),
   `Theme.ds4` (system-appearance colors); remove the NSTextView stack.
7. Wire `MessageBubble` / `ThinkingDisclosure` to pick mode by `isStreaming` and render thinking only
   when expanded; remove the `.fixedSize` / greedy-width workarounds.
8. Prune the obsolete `MarkdownTextTests`; add `preprocess` tests.
9. `swift build && swift test`; run the app; stress + smoke (incl. light/dark) verification against the
   Step 0 baseline.
