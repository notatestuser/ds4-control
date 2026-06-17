# Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Settings GUI field that controls only the `ds4-server --host` bind address.

**Architecture:** Persist the bind host in `AppState`, normalize it at the GUI launch/restart boundary, and require `SupervisorService.start/restart` callers to pass an explicit `host:` value. Keep DS4 Control's own probes, built-in chat, and Terminal agent wrappers hardcoded to `127.0.0.1`.

**Tech Stack:** Swift 6, SwiftUI, Combine `ObservableObject`, SwiftPM, XCTest.

### Task 1: AppState Host Persistence And Normalization

**Files:**

- Modify: `Sources/DS4Control/AppState.swift`
- Modify: `Tests/DS4ControlTests/AppStateTests.swift`

- [ ] **Step 1: Write the failing AppState tests**

  Add assertions in `Tests/DS4ControlTests/AppStateTests.swift`:

  - A fresh `AppState` defaults `host` to `127.0.0.1`.
  - `host` persists through `UserDefaults`.
  - `normalizeHostForLaunch()` trims `"  0.0.0.0\n"` to `"0.0.0.0"` and writes `"0.0.0.0"` back to `AppState.host`.
  - `normalizeHostForLaunch()` converts whitespace-only input to `"127.0.0.1"` and writes that value back.

- [ ] **Step 2: Run the focused AppState tests and confirm they fail**

  Run:

  ```bash
  rtk test swift test --filter AppStateTests
  ```

  Expected: fail because `AppState.host` and `normalizeHostForLaunch()` do not exist.

- [ ] **Step 3: Implement AppState host storage**

  In `Sources/DS4Control/AppState.swift`, add:

  - `static let defaultHost = "127.0.0.1"`
  - `@Published var host: String { didSet { d.set(host, forKey: "host") } }`
  - `host = d.string(forKey: "host") ?? Self.defaultHost` in `init`.

- [ ] **Step 4: Implement the launch-boundary normalization helper**

  In `AppState`, add:

  ```swift
  func normalizeHostForLaunch() -> String {
      let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
      let normalized = trimmed.isEmpty ? Self.defaultHost : trimmed
      if host != normalized { host = normalized }
      return normalized
  }
  ```

- [ ] **Step 5: Run the focused AppState tests and confirm they pass**

  Run:

  ```bash
  rtk test swift test --filter AppStateTests
  ```

  Expected: pass.

### Task 2: Supervisor Bind Host Argument And GUI Handoff

**Files:**

- Modify: `Sources/DS4Control/Services/SupervisorService.swift`
- Modify: `Sources/DS4Control/Views/SettingsView.swift`
- Modify: `Sources/DS4Control/Views/ModelRowView.swift`
- Modify: `Tests/DS4ControlTests/SupervisorStateMachineTests.swift`
- Modify: `Tests/DS4ControlTests/SupervisorIntegrationTests.swift`
- Create or modify: `Tests/DS4ControlTests/GUIHostOptionSourceTests.swift`
- Modify other files only where the compiler reports direct `start` or `restart` calls.

- [ ] **Step 1: Write or update the failing SupervisorService launch-argument test**

  In `SupervisorStateMachineTests`, add or update a test that calls:

  ```swift
  s.start(
      variant: .flash,
      flashQuant: .q2q4,
      ctx: 250_000,
      host: "0.0.0.0",
      port: 8000,
      power: nil
  )
  ```

  Assert the fake runner arguments contain `--host` followed by `"0.0.0.0"`.

- [ ] **Step 2: Run the focused supervisor tests and confirm they fail**

  Run:

  ```bash
  rtk test swift test --filter SupervisorStateMachineTests
  ```

  Expected: fail because `SupervisorService.start` does not accept `host:`.

- [ ] **Step 3: Require `host:` in `SupervisorService.start`**

  Change `SupervisorService.start` to:

  ```swift
  func start(
      variant: Variant,
      flashQuant: FlashQuant,
      ctx: Int,
      host: String,
      port: Int,
      power: Int?,
      kvDiskDir: URL? = nil
  )
  ```

  Change the launch args from hardcoded `"127.0.0.1"` to `host`:

  ```swift
  var args = ["-m", gguf.path, "--ctx", "\(ctx)", "--host", host, "--port", "\(port)", "--metal"]
  ```

- [ ] **Step 4: Require `host:` in `SupervisorService.restart`**

  Change `SupervisorService.restart` to accept `host: String` and pass it into the deferred `start` call. Do not change `resumeRunningServerIfAny`, `defaultServerProbe`, health polling, `ChatService`, or `AgentLauncher`; they must stay loopback-only.

- [ ] **Step 5: Update direct test call sites**

  Add `host: AppState.defaultHost` or `host: "127.0.0.1"` to existing direct `start` and `restart` calls in supervisor tests. Use `"0.0.0.0"` only in the launch-argument test that proves the new behavior.

- [ ] **Step 6: Add GUI handoff and Settings copy**

  In `SettingsView`, add the `Bind host` text field, the explanatory copy, and
  call `app.normalizeHostForLaunch()` before `supervisor.restart`.

  In `ModelRowView`, call `app.normalizeHostForLaunch()` before
  `supervisor.start` and pass that value as `host:`.

- [ ] **Step 7: Add source-level GUI handoff tests**

  Create `Tests/DS4ControlTests/GUIHostOptionSourceTests.swift` with tests that
  assert `SettingsView.swift` and `ModelRowView.swift` contain the normalized
  host handoff and that Settings contains the required explanatory copy.

- [ ] **Step 8: Run the focused supervisor and GUI tests and confirm they pass**

  Run:

  ```bash
  rtk test swift test --filter SupervisorStateMachineTests
  rtk test swift test --filter GUIHostOptionSourceTests
  ```

  Expected: pass.

### Task 3: Loopback Client Regression Tests

**Files:**

- Verify: `Sources/DS4Control/Services/ChatService.swift`
- Verify: `Sources/DS4Control/Services/AgentLauncher.swift`
- Verify: `Tests/DS4ControlTests/ChatServiceTests.swift`
- Verify: `Tests/DS4ControlTests/AgentLauncherTests.swift`

- [ ] **Step 1: Run loopback client tests**

  Run:

  ```bash
  rtk test swift test --filter ChatServiceTests
  rtk test swift test --filter AgentLauncherTests
  ```

  Expected: pass, with assertions still checking `127.0.0.1`.

- [ ] **Step 2: Confirm no bind-host setting leaked into client URL builders**

  Inspect `ChatService.makeRequest`, `AgentLauncher.piModelsJSON`, and
  `AgentLauncher.wrapperScript`. They should continue using hardcoded
  `127.0.0.1`.

### Task 4: Full Test Suite And Cleanup

**Files:**

- Modify only files identified by compiler errors from the new required `host:` parameter.
- Verify: `Sources/DS4Control/DS4ControlApp.swift`

- [ ] **Step 1: Run the full test suite to surface missing call sites**

  Run:

  ```bash
  rtk test swift test
  ```

  Expected before final call-site cleanup: compiler errors for any remaining direct `start` or `restart` calls missing `host:`.

- [ ] **Step 2: Fix only missing `host:` call sites**

  For each compile error:

  - GUI start/restart paths use `app.normalizeHostForLaunch()`.
  - Non-GUI tests or fixture setup use `host: AppState.defaultHost` or `"127.0.0.1"`.
  - Do not change `ChatService.makeRequest`, `AgentLauncher.piModelsJSON`, `AgentLauncher.wrapperScript`, `SupervisorService.defaultServerProbe`, `resumeRunningServerIfAny`, or health polling URLs away from `127.0.0.1`.

- [ ] **Step 3: Run the full test suite**

  Run:

  ```bash
  rtk test swift test
  ```

  Expected: pass.

### Task 5: Commit Implementation And Push Branch

**Files:**

- Commit: source and test files changed by Tasks 1-4.
- Do not commit unrelated untracked files such as `.serena/`, `AGENTS.md`, or existing untracked `docs/` assets.

- [ ] **Step 1: Review the diff**

  Run:

  ```bash
  rtk git diff
  rtk git status --short --branch
  ```

  Expected: only the host-option source/test files and Superpowers docs are changed or ahead on `gui-host-option`.

- [ ] **Step 2: Commit implementation and tests**

  Run:

  ```bash
  rtk git add Sources/DS4Control/AppState.swift Sources/DS4Control/Services/SupervisorService.swift Sources/DS4Control/Views/SettingsView.swift Sources/DS4Control/Views/ModelRowView.swift Tests/DS4ControlTests/AppStateTests.swift Tests/DS4ControlTests/SupervisorStateMachineTests.swift Tests/DS4ControlTests/SupervisorIntegrationTests.swift Tests/DS4ControlTests/GUIHostOptionSourceTests.swift
  rtk git commit -m "Add GUI bind host option"
  ```

- [ ] **Step 3: Push `gui-host-option`**

  Run:

  ```bash
  rtk git push origin gui-host-option
  ```

  Expected: remote `gui-host-option` contains the spec commit and implementation commit. `main` is not pushed.
