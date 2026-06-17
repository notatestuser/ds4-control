# GUI Host Option Design

## Goal

Add a GUI setting that lets the user choose the bind address passed to `ds4-server`
as `--host`, while keeping DS4 Control's built-in clients connected to the local
loopback address.

## Behavior

`AppState` will gain a persisted bind-host setting named `host`, defaulting to
`127.0.0.1`.

The normalized host is `host.trimmingCharacters(in: .whitespacesAndNewlines)`,
with `127.0.0.1` used when the trimmed value is empty.

When the user starts or restarts the server, DS4 Control will normalize the
current host setting, write the normalized value back to `AppState`, pass it to
`SupervisorService`, and `SupervisorService` will launch `ds4-server` with:

```text
--host <host>
```

The host setting affects only the server bind address. It does not change the
addresses used by built-in clients:

- Startup, resume, and health probes continue to call `/v1/models` on
  `127.0.0.1`.
- Built-in chat continues to call `127.0.0.1`.
- Terminal agent wrapper scripts continue to use `127.0.0.1`.

This preserves existing local behavior by default. If the user enters `0.0.0.0`,
`ds4-server` listens on all network interfaces, but DS4 Control itself still
talks to the server through loopback.

## UI

The Settings window's Server section will add a plain text field for the bind
host near the existing Port control.

The field will include small descriptive text:

```text
Binds ds4-server to this address. The app's built-in chat and Terminal agent still connect through 127.0.0.1. Use 0.0.0.0 to listen on all network interfaces.
```

No warning modal is needed for `0.0.0.0` in this pass. The inline small print is
the only user-facing explanation.

## Validation

Validation will stay intentionally light:

- Trim whitespace before launch and restart.
- If the trimmed value is empty, use `127.0.0.1`.
- Persist the normalized value so accidental whitespace does not remain in user
  defaults.
- Do not reject hostnames, specific LAN IPs, or other bind names that
  `ds4-server` may support.

Normalization happens at the launch/restart boundary, before calling
`SupervisorService`. This keeps launch arguments and persisted defaults in
agreement after any Start or Apply & Restart attempt.

## Tests

The implementation will be covered through existing test seams:

- `AppStateTests` verifies `host` defaults to `127.0.0.1` and persists.
- `SupervisorStateMachineTests` verifies `start` passes the configured bind host
  as the value after `--host`.
- GUI handoff coverage verifies the Model row Start/Retry-start path and the
  Settings Apply & Restart path pass the normalized `app.host` value rather than
  relying on a `SupervisorService` default.
- Normalization coverage verifies a whitespace-padded host is launched as the
  trimmed value and persisted back to `AppState`; an empty or whitespace-only
  host launches and persists as `127.0.0.1`.
- A focused Settings source or helper test verifies the explanatory copy is
  present in the Settings UI.
- Existing `ChatServiceTests` and `AgentLauncherTests` continue asserting
  `127.0.0.1` URLs, proving the bind-host setting does not leak into built-in
  clients.
- `swift test` is the main verification command.

## Commit Plan

Use small, atomic commits on `gui-host-option`:

1. Commit this design spec only.
2. Commit the implementation and tests separately after the spec is reviewed.
