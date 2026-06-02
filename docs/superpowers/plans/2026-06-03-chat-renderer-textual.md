# Chat Renderer → Textual + Incremental Block Streaming — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the custom NSTextView markdown renderer with the Textual SwiftUI package behind a one-file seam, with an incremental block-streaming layer, eliminating the chat-freeze and cutting maintenance.

**Architecture:** Pure-SwiftUI rendering removes the `NSView` width↔height self-sizing loop that caused the freeze. Finished assistant bubbles render as one `StructuredText`; the streaming bubble renders block-split — completed markdown blocks frozen via `.equatable()`, only the trailing block re-parsing per tick. `ChatViewModel`'s flush loop gains a ~250 ms thinking cadence and a single-in-flight guard (adaptive backpressure). Only `MarkdownText.swift` imports Textual.

**Tech Stack:** Swift 6 / SwiftUI / macOS 15; `gonzalezreal/textual` (MIT, v0.3.x); existing `ChatService`/SSE stream untouched.

**Spec:** `docs/superpowers/specs/2026-06-03-chat-renderer-textual-design.md`

**Execution order (respects task dependencies):** 1 → 2 → 3 → 4 → 9 → 5 → 6 → 7 → 8. Task numbers match the native task IDs; the document is ordered by execution, not numerically.

**Global gates (every commit must pass — these mirror CI `ci.yml`):**
```bash
swift format lint --strict --recursive Sources Tests   # CI lints --strict
swift build -c release -Xswiftc -warnings-as-errors     # CI builds warnings-as-errors
swift test                                              # authoritative
```
Run `swift format format --in-place --recursive Sources Tests` before committing to satisfy the strict lint.

## Reviewer Revisions (implementation handoff)

Verified against the live files — plan line refs, test helpers (`makeViewModel`, `awaitStreamCompletion`, `@MainActor` test class), `ChatMessage`'s defaulted init, and CI (`macos-26`; gates mirror `ci.yml`) are all accurate. The following **override** the task text below where they conflict.

**R1 — In-flight guard: next-tick cooldown, not a microtask clear (Task 9).**
The planned `Task { @MainActor in self?.updateInFlight = false }` clears the flag before the next 33 ms tick, so it effectively never skips (the empty-buffer `guard mutated else return` was the real backpressure). Clear it inside the *next* `tickFlush` instead — a one-interval cooldown after each applied mutation, which genuinely caps the apply rate under sustained streaming while leaving idle ticks untouched. Use these in place of Task 9 Step 3(b/c):

```swift
@MainActor
func tickFlush() {
    // Single-in-flight guard as a cooldown: a tick landing right after a mutation treats the
    // prior render as still settling and skips, clearing the flag so the next tick resumes.
    // Sustained streaming → applies at most ~every other tick (~66ms); idle ticks unaffected.
    if updateInFlight {
        updateInFlight = false
        return
    }
    flushTickCount &+= 1
    let includeThinking = flushTickCount % Self.thinkingFlushEveryNTicks == 0
    applyPendingDeltas(includeThinking: includeThinking, force: false)
}
```
and the tail of `applyPendingDeltas`:
```swift
        guard mutated else { return }
        if !force { updateInFlight = true }   // cleared by the next tickFlush (cooldown)
```
Add to Task 9 Step 1 (requires `tickFlush` internal, like the other guard members):
```swift
    func testTickFlushCooldownSkipsNextTick() {
        let viewModel = makeViewModel(deltas: [])
        let id = UUID()
        viewModel.messages = [ChatMessage(id: id, role: .assistant, content: "", isStreaming: true)]
        viewModel.streamingMessageID = id
        viewModel.bufferContentDelta("A"); viewModel.tickFlush()   // applies → in-flight
        XCTAssertEqual(viewModel.messages[0].content, "A")
        viewModel.bufferContentDelta("B"); viewModel.tickFlush()   // cooldown → skipped
        XCTAssertEqual(viewModel.messages[0].content, "A")
        viewModel.tickFlush()                                      // resumes → applies "B"
        XCTAssertEqual(viewModel.messages[0].content, "AB")
    }
```

**R2 — `stripTaggedBlocks` must handle an inline `<tag>…</tag>` line (Task 5).**
The planned loop scans *following* lines for the close, so a single `<think>x</think>` line over-consumes everything after it. Replace the function with:
```swift
    static func stripTaggedBlocks(_ s: String) -> String {
        var out: [String] = []
        var lines = s.components(separatedBy: .newlines)[...]
        while let line = lines.first {
            lines = lines.dropFirst()
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("<"), let tag = extractOpeningTag(trimmed),
                strippedTags.contains(tag)
            else {
                out.append(line)
                continue
            }
            if trimmed.contains("</\(tag)>") { continue }  // inline open+close → drop this line only
            while let next = lines.first,
                extractClosingTag(next.trimmingCharacters(in: .whitespaces)) != tag
            {
                lines = lines.dropFirst()
            }
            lines = lines.dropFirst()  // consume the closing tag line (no-op at EOF)
        }
        return out.joined(separator: "\n")
    }
```
Add to Task 5's `MarkdownTextTests`:
```swift
    func testPreprocessStripsInlineThinkingLine() {
        XCTAssertEqual(MarkdownText.preprocess("Before\n<think>x</think>\nAfter"), "Before\nAfter")
    }
```

**R3 — Endorse split-on-raw + preprocess-per-block (Task 5, no change).** The spec wrote `splitBlocks(preprocess(content))`; the plan splits raw and preprocesses each `MarkdownBlockView`. Keep the plan's order — with `.equatable()` only the live tail re-preprocesses (O(tail)), and `deLaTeXed` doesn't change block boundaries; the rare divergence (a stripped tag block containing an interior blank line) is reconciled when the bubble collapses to single-view on finalize.

## File Structure

| File | Status | Responsibility | Imports Textual |
|---|---|---|---|
| `Sources/DS4Control/ViewModels/ChatViewModel.swift` | Modify | Flush loop: 33 ms content / ~250 ms thinking cadence + MainActor single-in-flight guard. Public surface unchanged. | No |
| `Sources/DS4Control/Views/MarkdownBlocks.swift` | Create | `enum MarkdownBlocks` — pure `splitBlocks(_:)` (fence-aware block splitter). Dependency-free. | No |
| `Sources/DS4Control/Views/MarkdownText.swift` | Rewrite | `MarkdownText` (single-view), `StreamingMarkdownText` (block-split), `preprocess`/`deLaTeXed`/tag-strip, `ds4MarkdownStyle()`. **Only** Textual importer. | Yes |
| `Sources/DS4Control/Views/ChatView.swift` | Modify | `MessageBubble`/`ThinkingDisclosure` pick render mode by `isStreaming`; thinking renders only when expanded; drop `.fixedSize` workarounds. | No |
| `Tests/DS4ControlTests/MarkdownBlocksTests.swift` | Create | `splitBlocks` unit tests. | No |
| `Tests/DS4ControlTests/MarkdownTextTests.swift` | Rewrite | Keep `deLaTeXed` tests; add `preprocess` tag-strip tests; delete NSTextView-internal tests. | No |
| `Tests/DS4ControlTests/ChatViewModelTests.swift` | Modify | Add cadence + in-flight-guard tests. | No |
| `Package.swift` | Modify | Add Textual dep; bump `.macOS(.v14)` → `.macOS(.v15)`. | — |

---

### Task 1: Commit the streaming throttle work in isolation

**Goal:** Land the already-written 33 ms throttle as its own commit so the renderer swap is a clean, separate change.

**Files:**
- Commit: `Sources/DS4Control/ViewModels/ChatViewModel.swift` (working-tree changes)
- Commit: `Tests/DS4ControlTests/ChatViewModelTests.swift` (working-tree changes)
- Leave modified (subsumed by Task 5): `Sources/DS4Control/Views/MarkdownText.swift`, `Tests/DS4ControlTests/MarkdownTextTests.swift`

**Acceptance Criteria:**
- [ ] A commit contains only the two ChatViewModel files.
- [ ] `swift test` green.

**Verify:** `swift test` → all tests pass; `git show --stat HEAD` lists exactly the two files.

**Steps:**

- [ ] **Step 1: Confirm the current tree is green**

```bash
swift build && swift test
```
Expected: PASS (the throttle + `testFinishFlushesBufferSynchronously` already present in the working tree).

- [ ] **Step 2: Stage and commit only the ChatViewModel throttle**

```bash
git add Sources/DS4Control/ViewModels/ChatViewModel.swift Tests/DS4ControlTests/ChatViewModelTests.swift
git commit -m "perf(chat): coalesce streaming token mutations onto a 33ms flush loop"
```

- [ ] **Step 3: Verify isolation**

```bash
git show --stat HEAD          # only the two ChatViewModel files
git status --short            # MarkdownText.swift + MarkdownTextTests.swift still modified (subsumed by Task 5)
```
Expected: HEAD touches 2 files; the two MarkdownText files remain modified (their placeholder-guard hunk dies in the Task 5 rewrite — no action needed now).

---

### Task 2: Confirm freeze cause + capture sample baseline (Step 0)

**Goal:** Prove the freeze is the NSView layout-loop (not a guess) and record a before-baseline to compare the new renderer against. No code changes.

**Files:** none (produces `/tmp/freeze-before.txt`).

**Acceptance Criteria:**
- [ ] A `sample` capture saved that shows the spinning stack in SwiftUI layout ↔ `IntrinsicTextView` sizing (`intrinsicContentSize` / `usedRect` / `ensureLayout`).
- [ ] One-paragraph note recording the dominant frames (paste into the PR description later).

**Verify:** `grep -E "intrinsicContentSize|usedRect|ensureLayout|NSTextView" /tmp/freeze-before.txt` → matches present.

**Steps:**

- [ ] **Step 1: Run the dev app detached**

```bash
pkill -f '.build/debug/DS4Control' 2>/dev/null
swift build
DS4_DIR="$PWD/external/ds4" nohup ./.build/debug/DS4Control >/tmp/ds4control-dev.log 2>&1 &
disown
```

- [ ] **Step 2: Trigger a long reply and capture the freeze**

Open the chat (menu-bar icon → chat), Start the server, send a prompt that yields a long multi-paragraph reply (or, without a server, paste a long multi-paragraph assistant message by sending several messages so the transcript overflows the viewport). When the main thread pegs:
```bash
PID=$(pgrep -f '.build/debug/DS4Control' | head -1)
/usr/bin/sample "$PID" 3 -file /tmp/freeze-before.txt   # bare `sample` is shadowed by pyenv on this machine
```

- [ ] **Step 3: Confirm the layout-loop signature**

```bash
grep -nE "intrinsicContentSize|usedRect\(for:|ensureLayout|NSTextView|AG::|Layout" /tmp/freeze-before.txt | head -40
```
Expected: heavy presence of NSTextView sizing + SwiftUI/AttributeGraph layout frames spinning. Record the top frames in a note. (If the freeze does not reproduce on `debug`, note that and proceed — the structural argument for removing the NSView bridge still holds; the Task 8 stress test is the forward gate.)

- [ ] **Step 4: Stop the dev app**

```bash
pkill -f '.build/debug/DS4Control'
```

---

### Task 3: Add Textual dependency + bump macOS floor to 15

**Goal:** Add Textual to the package and raise the deployment target. No call sites yet — the dependency is present and resolvable.

**Files:**
- Modify: `Package.swift`

**Acceptance Criteria:**
- [ ] `Package.swift` declares `.macOS(.v15)` and the Textual dependency + product.
- [ ] `swift build` resolves and compiles (Textual unused is fine).

**Verify:** `swift build` → Compiling/Build complete; `swift package show-dependencies | grep -i textual` → textual listed.

**Steps:**

- [ ] **Step 1: Find the current latest Textual version (do not hardcode blindly)**

```bash
git ls-remote --tags https://github.com/gonzalezreal/textual 'v*' | awk -F/ '{print $NF}' | sort -V | tail -5
```
Use the highest stable tag (e.g. `X.Y.Z`) in the next step.

- [ ] **Step 2: Edit `Package.swift`**

Change the platforms line:
```swift
    platforms: [.macOS(.v15)],
```
Add the dependency to the `Package(...)` call (a `dependencies:` array sits between `platforms:` and `targets:`):
```swift
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/textual", from: "X.Y.Z"),
    ],
```
Add the product to the `DS4Control` executable target's `dependencies:` (the target currently has none — add the array):
```swift
        .executableTarget(
            name: "DS4Control",
            dependencies: [
                .product(name: "Textual", package: "textual"),
            ],
            path: "Sources/DS4Control",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedLibrary("IOReport"),
            ]
        ),
```

- [ ] **Step 3: Resolve + build**

```bash
swift package resolve
swift build
```
Expected: Textual + transitive deps (swift-concurrency-extras, swiftui-math) resolve; build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "build: add Textual dependency and raise deployment target to macOS 15"
```

---

### Task 4: Implement splitBlocks + tests (MarkdownBlocks.swift)

**Goal:** A pure, fence-aware function that splits a (possibly partial) streaming markdown string into stabilized completed blocks plus a mutable trailing block.

**Files:**
- Create: `Sources/DS4Control/Views/MarkdownBlocks.swift`
- Create: `Tests/DS4ControlTests/MarkdownBlocksTests.swift`

**Contract:** `splitBlocks(_:) -> (completed: [String], tail: String)`. A block is *completed* only when a blank line at fence-depth 0 follows it. An open code fence (```` ``` ```` / `~~~`) keeps everything from the fence onward in `tail` until it closes. Blocks are trimmed of the blank-line delimiters (the renderer re-introduces spacing via its `VStack`); this is a content contract, not byte-identity.

**Acceptance Criteria:**
- [ ] Prose splits on blank lines; the last unterminated block is `tail`.
- [ ] A closed fenced code block is a completed block; an open fence stays entirely in `tail`.
- [ ] Empty input → `([], "")`; input with no blank line → `([], input)`.

**Verify:** `swift test --filter MarkdownBlocksTests` → all pass.

**Steps:**

- [ ] **Step 1: Write the failing tests**

Create `Tests/DS4ControlTests/MarkdownBlocksTests.swift`:
```swift
import XCTest

@testable import DS4Control

final class MarkdownBlocksTests: XCTestCase {
    func testEmptyInput() {
        let r = MarkdownBlocks.splitBlocks("")
        XCTAssertTrue(r.completed.isEmpty)
        XCTAssertEqual(r.tail, "")
    }

    func testNoBlankLineIsAllTail() {
        let r = MarkdownBlocks.splitBlocks("one line still streaming")
        XCTAssertTrue(r.completed.isEmpty)
        XCTAssertEqual(r.tail, "one line still streaming")
    }

    func testSplitsProseOnBlankLines() {
        let r = MarkdownBlocks.splitBlocks("First para.\n\nSecond para.\n\nThird in progress")
        XCTAssertEqual(r.completed, ["First para.", "Second para."])
        XCTAssertEqual(r.tail, "Third in progress")
    }

    func testTrailingBlankFlushesLastBlock() {
        let r = MarkdownBlocks.splitBlocks("Done para.\n\n")
        XCTAssertEqual(r.completed, ["Done para."])
        XCTAssertEqual(r.tail, "")
    }

    func testOpenFenceStaysInTail() {
        // A blank line *inside* an open fence is not a boundary; the whole open block is tail.
        let r = MarkdownBlocks.splitBlocks("Intro.\n\n```swift\nlet x = 1\n\nlet y = 2")
        XCTAssertEqual(r.completed, ["Intro."])
        XCTAssertEqual(r.tail, "```swift\nlet x = 1\n\nlet y = 2")
    }

    func testClosedFenceIsCompletedBlock() {
        let r = MarkdownBlocks.splitBlocks("```swift\nlet x = 1\n```\n\nAfter")
        XCTAssertEqual(r.completed, ["```swift\nlet x = 1\n```"])
        XCTAssertEqual(r.tail, "After")
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
swift test --filter MarkdownBlocksTests
```
Expected: FAIL — `MarkdownBlocks` is undefined.

- [ ] **Step 3: Implement `MarkdownBlocks.splitBlocks`**

Create `Sources/DS4Control/Views/MarkdownBlocks.swift`:
```swift
import Foundation

/// Pure, dependency-free markdown block splitting for incremental streaming.
///
/// `splitBlocks` separates a (possibly partial) markdown string into *completed* blocks —
/// safe to render once and freeze — and a *mutable tail* that may still grow with the next
/// token. A block is completed only when a blank line at fence-depth 0 follows it; an open
/// code fence keeps everything from the fence onward in the tail until it closes. Blocks are
/// trimmed of the blank-line delimiters; the renderer re-introduces spacing via its layout.
enum MarkdownBlocks {
    static func splitBlocks(_ input: String) -> (completed: [String], tail: String) {
        var completed: [String] = []
        var current: [String] = []
        var fenceOpen = false

        func flush() {
            let block = current.joined(separator: "\n")
            if !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                completed.append(block)
            }
            current.removeAll()
        }

        for line in input.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fenceOpen.toggle()
                current.append(line)
                continue
            }
            if !fenceOpen && trimmed.isEmpty {
                flush()  // blank line at depth 0 ends the current block
                continue
            }
            current.append(line)
        }
        // Whatever remains (including an unterminated open fence) is the mutable tail.
        let tail = current.joined(separator: "\n")
        return (completed, tail)
    }
}
```

- [ ] **Step 4: Run to verify pass**

```bash
swift format format --in-place Sources/DS4Control/Views/MarkdownBlocks.swift Tests/DS4ControlTests/MarkdownBlocksTests.swift
swift test --filter MarkdownBlocksTests
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/DS4Control/Views/MarkdownBlocks.swift Tests/DS4ControlTests/MarkdownBlocksTests.swift
git commit -m "feat(chat): add fence-aware splitBlocks for incremental markdown streaming"
```

---

### Task 9: Extend ChatViewModel flush loop — thinking cadence + in-flight guard

**Goal:** Flush thinking on a coarser ~250 ms cadence and never let a second update pile onto an unsettled one (adaptive backpressure), without losing any delta.

**Files:**
- Modify: `Sources/DS4Control/ViewModels/ChatViewModel.swift`
- Modify: `Tests/DS4ControlTests/ChatViewModelTests.swift`

**Design:** The 33 ms flush task calls `tickFlush()`. Content flushes every tick; thinking every 8th tick (~264 ms). `applyPendingDeltas(includeThinking:force:)` skips when `updateInFlight` is set (unless `force`); on a real mutation it sets `updateInFlight` and clears it on the next main-actor turn. `finish()`/`stop()` call it with `force: true` to drain everything synchronously (preserves `testFinishFlushesBufferSynchronously`). A few members become `internal` for deterministic testing.

**Acceptance Criteria:**
- [ ] Content and thinking are both fully present after a stream (no loss), thinking included.
- [ ] A `force: false` flush while `updateInFlight` is set does not mutate; a subsequent `force: true` flush drains it.
- [ ] All existing `ChatViewModelTests` still pass.

**Verify:** `swift test --filter ChatViewModelTests` → all pass.

**Steps:**

- [ ] **Step 1: Write the failing tests**

Append to `Tests/DS4ControlTests/ChatViewModelTests.swift` (inside the class):
```swift
    func testThinkingDeltasDeliveredAfterStream() async {
        let viewModel = ChatViewModel(
            model: "deepseek-v4-pro", port: { 8000 },
            streamProvider: { _, _, _ in
                AsyncThrowingStream { c in
                    c.yield(.reasoning("step one. "))
                    c.yield(.reasoning("step two."))
                    c.yield(.text("Answer."))
                    c.finish()
                }
            })
        viewModel.input = "go"
        viewModel.send()
        await awaitStreamCompletion(viewModel)
        XCTAssertEqual(viewModel.messages.last?.thinking, "step one. step two.")
        XCTAssertEqual(viewModel.messages.last?.content, "Answer.")
    }

    func testInFlightGuardSkipsThenForceDrains() {
        let viewModel = makeViewModel(deltas: [])
        let id = UUID()
        viewModel.messages = [ChatMessage(id: id, role: .assistant, content: "", isStreaming: true)]
        viewModel.streamingMessageID = id

        viewModel.bufferContentDelta("X")
        viewModel.applyPendingDeltas(includeThinking: true, force: false)  // applies, marks in-flight
        XCTAssertEqual(viewModel.messages[0].content, "X")
        XCTAssertTrue(viewModel.updateInFlight)

        viewModel.bufferContentDelta("Y")
        viewModel.applyPendingDeltas(includeThinking: true, force: false)  // skipped while in-flight
        XCTAssertEqual(viewModel.messages[0].content, "X")

        viewModel.applyPendingDeltas(includeThinking: true, force: true)   // force drains
        XCTAssertEqual(viewModel.messages[0].content, "XY")
    }
```

- [ ] **Step 2: Run to verify failure**

```bash
swift test --filter ChatViewModelTests
```
Expected: FAIL — `streamingMessageID`/`bufferContentDelta`/`applyPendingDeltas`/`updateInFlight` are private/undefined.

- [ ] **Step 3: Implement the cadence + guard**

In `ChatViewModel.swift`:

(a) Add state near the throttle block (after line 52, `streamingMessageID`):
```swift
    // Single-in-flight guard: never apply a second @Published mutation while a prior
    // one is still settling. A flush that finds this set skips (deltas keep buffering);
    // it is set on a real mutation and cleared on the next main-actor turn. Internal for
    // deterministic testing. There is no literal "render finished" callback in SwiftUI —
    // this is a serialization boundary that gives adaptive backpressure under load.
    private(set) var updateInFlight = false
    private var flushTickCount = 0
    private static let thinkingFlushEveryNTicks = 8  // 33ms × 8 ≈ 264ms thinking cadence
```
Change `streamingMessageID` from `private` to internal (drop `private`):
```swift
    var streamingMessageID: UUID?
```

(b) Point the flush loop at `tickFlush()` (replace the body of the loop started in `send()`, currently `await self?.flushPendingDeltas()`):
```swift
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.streamingFlushIntervalNanos)
                if Task.isCancelled { return }
                await self?.tickFlush()
            }
        }
```

(c) Drop `private` from `bufferContentDelta` / `bufferThinkingDelta` (they already exist); replace `flushPendingDeltas()` with the cadence-aware pair. Replace the existing `flushPendingDeltas()` method (lines 167-179) with:
```swift
    /// Timer entry point. Content flushes every tick; thinking every Nth tick.
    @MainActor
    func tickFlush() {
        flushTickCount &+= 1
        let includeThinking = flushTickCount % Self.thinkingFlushEveryNTicks == 0
        applyPendingDeltas(includeThinking: includeThinking, force: false)
    }

    /// Drain pending buffers into the streaming row. Skips while an update is in flight
    /// unless `force`. `force` is used by finish()/stop() to drain synchronously.
    @MainActor
    func applyPendingDeltas(includeThinking: Bool, force: Bool) {
        if !force && updateInFlight { return }
        guard let id = streamingMessageID,
              let index = messages.firstIndex(where: { $0.id == id }) else { return }
        var mutated = false
        if !pendingContentDelta.isEmpty {
            messages[index].content += pendingContentDelta
            pendingContentDelta = ""
            mutated = true
        }
        if includeThinking && !pendingThinkingDelta.isEmpty {
            messages[index].thinking += pendingThinkingDelta
            pendingThinkingDelta = ""
            mutated = true
        }
        guard mutated else { return }
        if !force {
            updateInFlight = true
            Task { @MainActor [weak self] in self?.updateInFlight = false }
        }
    }
```

(d) Update the three callers of the old `flushPendingDeltas()`:
- In `stop()` (line 131) replace `flushPendingDeltas()` with `applyPendingDeltas(includeThinking: true, force: true)`.
- In `finish(_:)` (line 185) replace `flushPendingDeltas()` with `applyPendingDeltas(includeThinking: true, force: true)`.
- Reset the tick counter in `finish(_:)`/`stop()` where `streamingMessageID = nil` is set: add `flushTickCount = 0`.

> Note: `hasPendingDelta` is no longer referenced after this change — delete the computed property (lines 45-47) to avoid an unused-symbol warning (`-warnings-as-errors` in CI).

- [ ] **Step 4: Run to verify pass**

```bash
swift format format --in-place Sources/DS4Control/ViewModels/ChatViewModel.swift Tests/DS4ControlTests/ChatViewModelTests.swift
swift build -Xswiftc -warnings-as-errors && swift test --filter ChatViewModelTests
```
Expected: PASS (including the pre-existing `testFinishFlushesBufferSynchronously`, which relies on the `force: true` drain in `finish`).

- [ ] **Step 5: Commit**

```bash
git add Sources/DS4Control/ViewModels/ChatViewModel.swift Tests/DS4ControlTests/ChatViewModelTests.swift
git commit -m "perf(chat): coarse thinking cadence + single-in-flight flush guard"
```

---

### Task 5: Rewrite MarkdownText.swift onto Textual

**Goal:** Replace the NSTextView renderer with pure-SwiftUI Textual views — single-view for finished content, block-split for streaming — keeping the `deLaTeXed`/tag-strip preprocessing. Delete the now-invalid renderer-internal tests so the suite compiles.

**Files:**
- Rewrite: `Sources/DS4Control/Views/MarkdownText.swift`
- Rewrite: `Tests/DS4ControlTests/MarkdownTextTests.swift` (delete NSTextView-internal cases; keep `deLaTeXed`; add `preprocess` tests — done here so the build stays green)

**API note:** Textual's documented surface is `StructuredText(markdown:)`, `.textual.structuredTextStyle(.default|.gitHub)`, and `.textual.textSelection(.enabled)`. We use `.default` (not the spec's `.gitHub`) because it derives from adaptive system colors, satisfying the light/dark requirement; if `.gitHub` is confirmed to adapt, either works. Confirm these exact modifier names against the resolved package (`.build/checkouts/textual`) while implementing; adjust spelling if the package differs (the seam is one file).

**Acceptance Criteria:**
- [ ] `MarkdownText` and `StreamingMarkdownText` build and render markdown (headings/code/lists/tables) with text selection.
- [ ] `MarkdownText.preprocess` strips `<tool_call>`/`<thinking>` blocks and applies `deLaTeXed`.
- [ ] `swift build` succeeds; `MarkdownText.swift` is the only file importing Textual.

**Verify:** `swift build -Xswiftc -warnings-as-errors` → success; `grep -rl "import Textual" Sources | wc -l` → `1`.

**Steps:**

- [ ] **Step 1: Replace `MarkdownText.swift` wholesale**

Overwrite `Sources/DS4Control/Views/MarkdownText.swift` with:
```swift
// Selectable markdown renderer for chat bubbles, backed by Textual (pure SwiftUI).
// Replaces the former NSTextView stack (SelectableMarkdownNSText / IntrinsicTextView):
// going pure-SwiftUI removes the NSView width↔height self-sizing loop that caused the chat
// freeze. This is the ONLY file that imports Textual — the dependency seam.

import SwiftUI
import Textual

/// Renders a complete (non-streaming) markdown string as one Textual document: one parse,
/// correct inter-block spacing, whole-message text selection. Used for finished assistant
/// bubbles and the thinking disclosure.
struct MarkdownText: View {
    let source: String

    init(_ source: String) { self.source = source }

    var body: some View {
        StructuredText(markdown: Self.preprocess(source))
            .ds4MarkdownStyle()
    }

    /// LaTeX cleanup + tag stripping applied before handing markdown to Textual. Pure and
    /// renderer-agnostic.
    static func preprocess(_ s: String) -> String {
        stripTaggedBlocks(deLaTeXed(s))
    }

    /// Light LaTeX cleanup so the model's math reads as text rather than raw source. DeepSeek
    /// wraps math in \[ \] \( \) $$, boxes answers with \boxed{…}, and uses a few macros. This
    /// strips wrappers and maps common symbols — not a TeX engine; unknown macros pass through.
    static func deLaTeXed(_ s: String) -> String {
        var t = s
        for d in ["\\[", "\\]", "\\(", "\\)", "$$"] { t = t.replacingOccurrences(of: d, with: "") }
        t = t.replacingOccurrences(of: #"\\boxed\s*\{([^{}]*)\}"#, with: "**$1**", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\\text\s*\{([^{}]*)\}"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\\frac\s*\{([^{}]*)\}\s*\{([^{}]*)\}"#, with: "$1/$2", options: .regularExpression)
        let symbols: [(String, String)] = [
            ("times", "×"), ("cdots", "⋯"), ("cdot", "·"), ("div", "÷"), ("pm", "±"),
            ("leq", "≤"), ("geq", "≥"), ("neq", "≠"), ("approx", "≈"), ("equiv", "≡"),
            ("infty", "∞"), ("rightarrow", "→"), ("Rightarrow", "⇒"), ("to", "→"),
            ("ldots", "…"), ("sqrt", "√"), ("pi", "π"), ("theta", "θ"), ("alpha", "α"),
            ("beta", "β"), ("sum", "∑"),
        ]
        for (name, sym) in symbols {
            t = t.replacingOccurrences(of: "\\\\" + name + "(?![A-Za-z])", with: sym, options: .regularExpression)
        }
        return t
    }

    // Tag blocks removed from answer content: tool plumbing, and reasoning tags (reasoning
    // arrives separately via reasoning_content → ChatMessage.thinking and renders in the
    // disclosure, so inline <thinking>/<think> in content is redundant).
    private static let strippedTags: Set<String> = [
        "tool_call", "tool_response", "tool_result", "thinking", "think",
    ]

    /// Drop whole `<tag>…</tag>` blocks (tag lines + body) for tags in `strippedTags`.
    static func stripTaggedBlocks(_ s: String) -> String {
        var out: [String] = []
        var lines = s.components(separatedBy: .newlines)[...]
        while let line = lines.first {
            lines = lines.dropFirst()
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("<"), trimmed.hasSuffix(">"),
                let tag = extractOpeningTag(trimmed), strippedTags.contains(tag)
            {
                while let next = lines.first,
                    extractClosingTag(next.trimmingCharacters(in: .whitespaces)) != tag
                {
                    lines = lines.dropFirst()
                }
                lines = lines.dropFirst()  // consume the closing tag
                continue
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    private static func extractOpeningTag(_ s: String) -> String? {
        guard s.hasPrefix("<"), !s.hasPrefix("</"), s.hasSuffix(">") else { return nil }
        let name = s.dropFirst().dropLast().prefix { $0.isLetter || $0 == "_" }
        return name.isEmpty ? nil : String(name)
    }

    private static func extractClosingTag(_ s: String) -> String? {
        guard s.hasPrefix("</"), s.hasSuffix(">") else { return nil }
        let name = s.dropFirst(2).dropLast().prefix { $0.isLetter || $0 == "_" }
        return name.isEmpty ? nil : String(name)
    }
}

/// Renders a streaming markdown string incrementally: completed blocks are frozen via
/// `.equatable()` (SwiftUI skips re-rendering a block whose text is unchanged), and only the
/// trailing incomplete block re-parses per tick. Bounds per-tick cost to O(tail).
struct StreamingMarkdownText: View {
    let source: String

    /// Gap between block views; tuned to match `MarkdownText`'s single-view inter-block
    /// spacing so there is no visual "settle" when the bubble collapses on finalize (Task 6).
    private static let blockSpacing: CGFloat = 8

    init(_ source: String) { self.source = source }

    var body: some View {
        let parts = MarkdownBlocks.splitBlocks(source)
        VStack(alignment: .leading, spacing: Self.blockSpacing) {
            ForEach(Array(parts.completed.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(markdown: block).equatable()
            }
            if !parts.tail.isEmpty {
                MarkdownBlockView(markdown: parts.tail)
            }
        }
    }
}

/// One markdown block rendered via Textual. `Equatable` on its source so SwiftUI skips
/// re-rendering frozen (completed) blocks while later blocks stream.
private struct MarkdownBlockView: View, Equatable {
    let markdown: String

    static func == (a: MarkdownBlockView, b: MarkdownBlockView) -> Bool { a.markdown == b.markdown }

    var body: some View {
        StructuredText(markdown: MarkdownText.preprocess(markdown))
            .ds4MarkdownStyle()
    }
}

extension View {
    /// The DS4 markdown look: Textual's adaptive `.default` style (tracks light/dark via the
    /// SwiftUI colorScheme) + native text selection. (The spec called this `Theme.ds4`;
    /// realized as a reusable modifier to avoid implementing the full `StructuredText.Style`.)
    func ds4MarkdownStyle() -> some View {
        self
            .textual.structuredTextStyle(.default)
            .textual.textSelection(.enabled)
    }
}
```

- [ ] **Step 2: Rewrite `MarkdownTextTests.swift` (keep deLaTeXed, add preprocess, drop internals)**

Overwrite `Tests/DS4ControlTests/MarkdownTextTests.swift` with:
```swift
import XCTest

@testable import DS4Control

final class MarkdownTextTests: XCTestCase {
    // deLaTeXed (unchanged behavior; renderer-agnostic)
    func testDeLaTeXBoxedAnswerBecomesBold() {
        let out = MarkdownText.deLaTeXed("All seven.\n\\[\n\\boxed{7}\n\\]")
        XCTAssertTrue(out.contains("**7**"))
        XCTAssertFalse(out.contains("\\boxed"))
        XCTAssertFalse(out.contains("\\["))
        XCTAssertFalse(out.contains("\\]"))
    }

    func testDeLaTeXStripsDelimitersAndMapsMacros() {
        XCTAssertEqual(MarkdownText.deLaTeXed("\\(x+1\\)"), "x+1")
        XCTAssertFalse(MarkdownText.deLaTeXed("$$a$$").contains("$"))
        XCTAssertEqual(MarkdownText.deLaTeXed("3 \\times 4"), "3 × 4")
        XCTAssertEqual(MarkdownText.deLaTeXed("\\frac{1}{2}"), "1/2")
        XCTAssertEqual(MarkdownText.deLaTeXed("\\text{hello}"), "hello")
    }

    func testDeLaTeXLongerMacroNotEatenByShorter() {
        XCTAssertEqual(MarkdownText.deLaTeXed("a \\cdots b"), "a ⋯ b")
        XCTAssertEqual(MarkdownText.deLaTeXed("a \\cdot b"), "a · b")
        XCTAssertEqual(MarkdownText.deLaTeXed("x \\leq y"), "x ≤ y")
        XCTAssertEqual(MarkdownText.deLaTeXed("\\unknown"), "\\unknown")
    }

    // preprocess tag stripping (replaces the old hidden-tag attributedString test)
    func testPreprocessStripsToolCallBlock() {
        let out = MarkdownText.preprocess("<tool_call>\nsecret\n</tool_call>")
        XCTAssertFalse(out.contains("secret"))
    }

    func testPreprocessStripsThinkingBlockButKeepsAnswer() {
        let out = MarkdownText.preprocess("<thinking>\nhidden reasoning\n</thinking>\nThe answer is 42.")
        XCTAssertFalse(out.contains("hidden reasoning"))
        XCTAssertTrue(out.contains("The answer is 42."))
    }

    func testPreprocessKeepsOrdinaryMarkdown() {
        let out = MarkdownText.preprocess("## Heading\n\n- item")
        XCTAssertTrue(out.contains("## Heading"))
        XCTAssertTrue(out.contains("- item"))
    }
}
```

- [ ] **Step 3: Build (no `import AppKit` left in the rewritten files; remove if the build flags it)**

```bash
swift format format --in-place Sources/DS4Control/Views/MarkdownText.swift Tests/DS4ControlTests/MarkdownTextTests.swift
swift build -Xswiftc -warnings-as-errors
swift test
```
Expected: build succeeds; tests pass. If Textual's modifier names differ from the API note, fix them in `ds4MarkdownStyle()` / `StructuredText(markdown:)` only.

- [ ] **Step 4: Confirm the seam**

```bash
grep -rl "import Textual" Sources    # expect exactly: Sources/DS4Control/Views/MarkdownText.swift
```

- [ ] **Step 5: Commit**

```bash
git add Sources/DS4Control/Views/MarkdownText.swift Tests/DS4ControlTests/MarkdownTextTests.swift
git commit -m "feat(chat): render bubbles with Textual (single-view + block-split streaming)"
```

---

### Task 6: Wire bubbles to pick render mode by isStreaming

**Goal:** `MessageBubble` uses `StreamingMarkdownText` while streaming and `MarkdownText` when finished; `ThinkingDisclosure` renders reasoning via `MarkdownText` only when expanded; remove the NSTextView-era `.fixedSize` workarounds.

**Files:**
- Modify: `Sources/DS4Control/Views/ChatView.swift`

**Acceptance Criteria:**
- [ ] Streaming assistant content renders via `StreamingMarkdownText`; finished via `MarkdownText`.
- [ ] Thinking content is built only when the disclosure is expanded.
- [ ] No `.fixedSize` remains in `ThinkingDisclosure`; the app builds and runs.

**Verify:** `swift build` → success; manual: run the app, stream a reply, expand/collapse thinking.

**Steps:**

- [ ] **Step 1: Switch the assistant content view by streaming state**

In `ChatView.swift` `MessageBubble.body`, replace the assistant branch (currently lines 259-263):
```swift
                        if message.role == .assistant {
                            if message.isStreaming {
                                StreamingMarkdownText(message.content)
                            } else {
                                MarkdownText(message.content)
                            }
                        } else {
                            Text(message.content)
                        }
```
(The former `" "` placeholder for empty streaming content is dropped — Textual sizes empty content harmlessly, and the `GeneratingIndicator` row already covers the pre-first-token window.)

- [ ] **Step 2: Render thinking via MarkdownText only when expanded; drop `.fixedSize`**

Replace `ThinkingDisclosure` (lines 314-357) with:
```swift
/// Think-Max reasoning, hidden by default in a collapsed disclosure. Content is built only
/// when expanded, so collapsed reasoning costs nothing to render. State is per-message (the
/// bubble carries `.id(message.id)`), so expansion sticks per reply. Pure SwiftUI throughout
/// (Textual), so the old `.fixedSize` greedy-width guards are no longer needed.
struct ThinkingDisclosure: View {
    let text: String
    let streaming: Bool
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if expanded {
                MarkdownText(text)
                    .opacity(0.9)
                    .padding(.top, 4)
            }
        } label: {
            Label(streaming ? "Thinking…" : "Thinking", systemImage: "brain")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
```

- [ ] **Step 3: Build, run, and tune the seam spacing**

```bash
swift format format --in-place Sources/DS4Control/Views/ChatView.swift
swift build -Xswiftc -warnings-as-errors && swift test
pkill -f '.build/debug/DS4Control' 2>/dev/null
DS4_DIR="$PWD/external/ds4" nohup ./.build/debug/DS4Control >/tmp/ds4control-dev.log 2>&1 &
disown
```
Manually stream a multi-paragraph reply with a code block. Watch the moment it finalizes: if block spacing visibly "settles" (split→single), adjust `StreamingMarkdownText.blockSpacing` in `MarkdownText.swift` until streaming and finished spacing match. Expand/collapse the thinking disclosure during and after streaming.

- [ ] **Step 4: Commit**

```bash
git add Sources/DS4Control/Views/ChatView.swift Sources/DS4Control/Views/MarkdownText.swift
git commit -m "feat(chat): bubbles render by streaming state; thinking renders lazily on expand"
```

---

### Task 7: Prune obsolete renderer tests; confirm preprocess coverage

**Goal:** Ensure no test references deleted NSTextView internals and that `deLaTeXed` + `preprocess` coverage is intact. (Most of this happened in Task 5's test rewrite; this task is the verification + any cleanup.)

**Files:**
- Verify/adjust: `Tests/DS4ControlTests/MarkdownTextTests.swift`

**Acceptance Criteria:**
- [ ] No test references `MarkdownText.attributedString`, `IntrinsicTextView`, `applyAttributed`, or heading-scale internals.
- [ ] `deLaTeXed` and `preprocess` tag-strip tests are present and pass.

**Verify:** `grep -rE "attributedString|IntrinsicTextView|applyAttributed|headingPointSize" Tests` → no matches; `swift test` → green.

**Steps:**

- [ ] **Step 1: Scan for dangling references to deleted internals**

```bash
grep -rnE "attributedString|IntrinsicTextView|applyAttributed|headingPointSize|HeadingGoldenScale" Tests Sources
```
Expected: no matches. If any remain (e.g., another test file referenced them), delete those cases.

- [ ] **Step 2: Run the full suite**

```bash
swift test
```
Expected: PASS. (`MarkdownBlocksTests`, the rewritten `MarkdownTextTests`, and `ChatViewModelTests` all green.)

- [ ] **Step 3: Commit (only if Step 1 required edits)**

```bash
git add Tests/DS4ControlTests/MarkdownTextTests.swift
git commit -m "test(chat): drop NSTextView-internal renderer tests"
```

---

### Task 8: Verify (stress + smoke, light/dark) and confirm CI floor

**Goal:** Prove the new renderer is freeze-free and cheap on long replies, renders correctly in light and dark, and that CI stays green. Confirm no CI YAML change is needed (runner is already `macos-26`).

**Files:**
- Verify: `.github/workflows/ci.yml` (runner already `macos-26`; no edit expected), `.github/workflows/release.yml` (uses a reusable workflow; no edit expected)

**Acceptance Criteria:**
- [ ] Long-reply stream stays responsive (no runaway CPU in `sample`), no freeze — compared to the Task 2 baseline.
- [ ] Renders correctly in both light and dark appearance.
- [ ] `swift format lint --strict`, release build (`-warnings-as-errors`), and `swift test` all pass.

**Verify:** the three global gate commands pass; `sample` of a long stream shows no layout spin.

**Steps:**

- [ ] **Step 1: Full local CI gate**

```bash
swift format lint --strict --recursive Sources Tests
swift build -c release -Xswiftc -warnings-as-errors
swift test
```
Expected: all pass.

- [ ] **Step 2: Long-reply stress (the acceptance gate)**

```bash
pkill -f '.build/debug/DS4Control' 2>/dev/null
swift build
DS4_DIR="$PWD/external/ds4" nohup ./.build/debug/DS4Control >/tmp/ds4control-dev.log 2>&1 &
disown
```
Start the server, enable Max Think, send a prompt that produces a long (8–10k token) reply mixing prose, several fenced code blocks, a table, and lists. While it streams:
```bash
PID=$(pgrep -f '.build/debug/DS4Control' | head -1)
/usr/bin/sample "$PID" 3 -file /tmp/freeze-after.txt
```
Expected: no sustained 100% main-thread spin; `grep -cE "intrinsicContentSize|usedRect" /tmp/freeze-after.txt` → `0` (the NSTextView path is gone). Scrolling stays smooth; the streaming bubble updates without piling up.

- [ ] **Step 3: Light/dark check**

Toggle System Settings → Appearance (or the chat window's effective appearance). Confirm bubble text, code blocks, and the thinking disclosure are legible and correctly colored in both modes.

- [ ] **Step 4: Confirm CI needs no floor edit**

```bash
grep -n "runs-on" .github/workflows/ci.yml      # macos-26 — already ≥ the macOS 15 target
```
No YAML change required (the macOS-15 deployment target builds fine on the macOS-26 runner; release uses the shared reusable workflow). If a future runner pin were below 15, that's where it would change — not the case today.

- [ ] **Step 5: Stop the dev app and finalize**

```bash
pkill -f '.build/debug/DS4Control'
```
Record the before/after `sample` comparison in the PR description. The branch is ready for review/merge.

---

## Self-Review

**Spec coverage:**
- macOS 15 floor → Task 3. ✓
- Textual dep + seam → Tasks 3, 5 (one-file `import Textual`). ✓
- `splitBlocks` (fence-aware) → Task 4. ✓
- Single-view finished / block-split streaming / collapse on finalize → Tasks 5, 6. ✓
- Thinking single-view + render-only-when-expanded + ~250 ms cadence → Tasks 9 (cadence), 6 (lazy render). ✓
- Single-in-flight guard (both content + thinking) → Task 9. ✓
- System-appearance theme → Task 5 (`ds4MarkdownStyle` on `.default`), verified Task 8. ✓
- `deLaTeXed` + tag-strip preprocess kept → Task 5. ✓
- Step 0 sample baseline + stress gate → Tasks 2, 8. ✓
- Keep VM/ChatService/SSE; prune NSTextView tests → Tasks 1, 7. ✓
- CI floor → Task 8 (no YAML change needed; documented). ✓

**Placeholder scan:** No TBD/TODO. The two "verify against the resolved package" notes (Textual modifier spelling; exact latest version) are deliberate external-API confirmations with concrete fallback locations, not unfilled gaps.

**Type consistency:** `MarkdownBlocks.splitBlocks(_) -> (completed:[String], tail:String)` used identically in Task 4 and Task 5. `MarkdownText.preprocess`/`deLaTeXed`/`stripTaggedBlocks` defined in Task 5, referenced by Task 5 tests. `applyPendingDeltas(includeThinking:force:)`, `tickFlush()`, `updateInFlight`, `streamingMessageID`, `bufferContentDelta` — defined and referenced consistently across Task 9 code + tests. `StreamingMarkdownText`/`MarkdownText` referenced in Task 6 match Task 5 definitions.

**Known caveats (documented, accepted):** `.equatable()` frozen blocks may not recolor if system appearance toggles mid-stream (tiny window — only the actively-streaming message; finished bubbles are single-view and recolor normally). Open code fences keep the whole block in the tail (O(open-block) per tick until closed). Both are in the spec's risk table.
