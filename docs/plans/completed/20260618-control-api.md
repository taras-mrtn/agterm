# Control API (programmatic scripting over a unix socket)

## Overview

Add a kitty-style programmatic control channel to `agterm`: an external script can manage
workspaces and sessions, inject text into a session, and invoke control actions (split,
quick terminal, font, status bar) — all over a local unix domain socket, driven by a
companion `agtermctl` CLI.

- **Problem it solves:** today every action is GUI-only (sidebar, menu bar, palettes).
  There is no way to drive `agterm` from a script.
- **Scope (locked in brainstorm):** personal scripting. Fire-and-forget commands. **No**
  terminal-output/scrollback streaming, **no** event subscription — explicitly out of scope.
- **Integration:** the server is a thin dispatcher onto the *existing* `AppActions` /
  `AppStore` seam — the same seam the toolbar, menu bar, and palettes already share. No
  business logic is duplicated; the control channel becomes a third caller of that seam.

## Context (from discovery)

- **Project:** native macOS SwiftUI terminal on libghostty. Two modules: host-free
  `agtermCore` (Foundation/Observation only, `swift test`) + an app target (SwiftUI + the
  libghostty/AppKit bridge). Pattern to mirror: the git layer — *pure decisions in
  `agtermCore`, all I/O in the app target*.
- **The seam already exists:** `AppActions` (`agterm/AppActions.swift`) + `AppStore`
  (`agtermCore/Sources/agtermCore/AppStore.swift`) own every mutation. Confirmed signatures (read
  from source):
  - `AppStore`: `addWorkspace(name:) -> Workspace`, `addSession(toWorkspace:cwd:) -> Session?`,
    `selectSession(_:)`, `renameSession(_:to:)`, `renameWorkspace(_:to:)`, `closeSession(_:)`,
    `removeWorkspace(_:)`, `moveSession(_:toWorkspace:at:)`, `setStatusBarHidden(_:)`,
    `session(withID:) -> Session?`; **split is id-addressed here**: `toggleSplit(_ sessionID:)`
    and `closeSplit(_ sessionID:)`. Properties `workspaces`, `selectedSessionID`,
    `statusBarHidden`, `activeSession`, `currentWorkspaceID`, `defaultWorkspaceName`,
    `canRemoveWorkspace`.
  - `AppActions`: **`toggleSplit()` is argument-less and operates on `store.activeSession` only**
    — it is NOT usable to split an arbitrary target. Targeted split must call
    `AppStore.toggleSplit(target)` / `closeSplit(target)` directly, then
    `AppActions.focusSplitPane(_:wantSplit:)` for focus. Font uses
    `GhosttySurfaceView.performBindingAction(_:)` (not `AppStore.setFontSize`, which is the
    persistence sink for the CELL_SIZE path).
- **Socket path rendezvous:** `PersistenceStore.directory` is private, but
  `PersistenceStore.defaultDirectory` is a public static (`~/Library/Application Support/agterm`).
  Both the app and the CLI derive the socket directory from it (or from `AGTERM_STATE_DIR`), so
  they agree without exposing the instance directory.
- **Text injection primitive exists:** `ghostty_surface_text(surface, const char*, len)`
  (GhosttyKit header line 1128). `ghostty_surface_key` also exists (future `session.key`,
  not v1). `GhosttySurfaceView.performBindingAction(_:)` already wraps the binding-action API
  (used for font).
- **UUIDs are stable across restarts:** `AppStore.restore(from:)` rebuilds sessions keyed by
  the persisted ids (`AppStore.swift:240`); `WorkspaceSnapshot`/`SessionSnapshot` carry
  `id: UUID`. A script can stash an id and it still resolves after a relaunch.
- **Quick terminal:** `QuickTerminalController.shared` has `toggle()`, `hide()`, `isVisible`,
  `currentSurface()` — but **no `show()`** (one-line glue needed).
- **Test isolation:** the app honors `AGTERM_STATE_DIR` for persistence; XCUITests use it for a
  hermetic temp dir and assert via polling `workspaces.json`. The socket reuses the same dir.
- **`agtermCore` has zero external dependencies today** (a stated value). The CLI will add
  `swift-argument-parser`, but only on the CLI targets — the `agtermCore` *library* target stays
  Foundation-only.

## Development Approach

- **testing approach:** TDD where practical — the pure `agtermCore` pieces (protocol codecs,
  target resolver, socket-path resolver) get tests first; the socket server and CLI are
  covered by end-to-end socket tests and arg-parsing tests.
- complete each task fully before moving to the next; make small, focused changes.
- **CRITICAL: every task MUST include new/updated tests** (success + error scenarios).
- **CRITICAL: all tests must pass before starting the next task.** Gate per task:
  `cd agtermCore && swift test` (host-free) and, for app-target tasks, the relevant
  `xcodebuild test … -only-testing:agtermUITests/ControlAPIUITests` case(s). The app must build.
- **CRITICAL: update this plan file when scope changes during implementation.**
- maintain backward compatibility: the control channel is additive and best-effort; if the
  socket fails to bind, the app still launches normally.

## Keep-in-sync convention (HARD — applies to this plan and all future feature work)

**Any new user action added to `AppActions`/`AppStore` is not "done" until it is drivable
from the socket.** Shipping a new action requires all four of:

1. a `Command` case (+ any args) in `agtermCore`'s control protocol,
2. a dispatch arm in `ControlServer`,
3. an `agtermctl` subcommand,
4. protocol round-trip + end-to-end tests for it.

This extends the existing "`AppActions` is shared by the toolbar and menu bar so the two
never drift" rule to a **third surface** (the control channel). It is written into
`CLAUDE.md` in Task 8 and referenced by every feature task here and later.

## Testing Strategy

- **unit tests (`agtermCore`, host-free, `swift test`):** round-trip encode/decode for every
  `ControlRequest`/`ControlResponse` shape; the pure target resolver across all cases
  (`active` present/nil, exact UUID, unique prefix, ambiguous, not-found, empty); the pure
  socket-path resolver (with/without `AGTERM_STATE_DIR`).
- **arg-parsing tests (`agtermctlKit`, host-free):** each CLI subcommand builds the correct
  `ControlRequest`; round-trip against an in-process stub socket server (no app host).
- **end-to-end (XCUITest `ControlAPIUITests`):** launch the real app with `AGTERM_STATE_DIR` +
  isolated socket, speak the socket directly (POSIX) from the test process, and assert via
  the `workspaces.json` file-polling oracle the existing sidebar tests use. `session.type` is
  verified the same way the split test verifies focus — type a command that writes to a file,
  then read the file back. Each app-target task adds its own e2e case(s); Task 7 adds the
  full script-style acceptance sequence.

## Progress Tracking

- mark completed items with `[x]` immediately when done.
- add newly discovered tasks with ➕ prefix; document blockers with ⚠️ prefix.
- keep the plan in sync with the actual work.

## Solution Overview

Three layers, placed to match the core/app split:

1. **Protocol + pure logic in `agtermCore`** (Foundation-only, `Codable`, `Sendable`):
   `Command` enum, `ControlArgs`, `ControlRequest`, `ControlResult`, `ControlResponse`, the
   tree-projection node types, the pure **target resolver**, and the pure **socket-path
   resolver**. Shared by the app and the CLI so the wire contract cannot drift.
2. **`ControlServer` in the app target** (`@MainActor`): owns the POSIX unix-domain-socket
   listener. Accept/read loop on a background `DispatchQueue`; each newline-delimited
   `ControlRequest` decoded, hopped to `@MainActor`, executed by calling the existing
   `AppActions`/`AppStore` methods (and a new thin `GhosttySurfaceView.inject(text:)` for
   input), response encoded and written back, connection closed.
3. **`agtermctl` CLI** (`swift-argument-parser`): subcommands mirror the catalog 1:1; opens the
   socket, sends one request, prints the response (`--json` for raw), exit code follows `ok`.
   Lives in the `agtermCore` SwiftPM package as `agtermctlKit` (testable lib) + a thin `agtermctl`
   executable, so it builds with `swift build` and needs no Xcode/GhosttyKit.

Key design decisions:
- **UUID is canonical**, with sugar: `active` (the selected session / current workspace) and
  git-style unique-prefix matching, so scripts rarely type a full UUID and never have to for
  "the current one".
- **No GUI on the API path:** `workspace.delete` returns an error instead of showing the
  confirm alert; nothing blocks on a modal.
- **Best-effort server:** bind failure logs and the app continues.

## Technical Details

### Wire protocol

One request per connection, newline-delimited JSON, request → single response → close.

```
request:  {"cmd":"session.type","target":"9f3c","args":{"text":"ls\n","select":true}}
response: {"ok":true,"result":{"id":"9f3c…"}}
          {"ok":false,"error":"ambiguous prefix '9f' → 9f3c…, 9fab…"}
```

Mutating commands return the new id in `result.id` so a script can create-then-use without a
second round-trip. `tree` returns `result.tree`.

### `agtermCore` type sketches (Foundation-only, `Codable`, `Sendable`)

```
enum Command: String, Codable, Sendable {
    case tree
    case workspaceNew = "workspace.new", workspaceRename = "workspace.rename"
    case workspaceDelete = "workspace.delete", workspaceSelect = "workspace.select"
    case sessionNew = "session.new", sessionClose = "session.close"
    case sessionSelect = "session.select", sessionRename = "session.rename"
    case sessionMove = "session.move", sessionType = "session.type", sessionSplit = "session.split"
    case quick                                   // mode: show|hide|toggle
    case fontInc = "font.inc", fontDec = "font.dec", fontReset = "font.reset"
    case statusbar                               // mode: on|off|toggle
}

struct ControlArgs: Codable, Sendable {         // all optional; bag of params
    var name: String?      // workspace/session rename, workspace.new
    var cwd: String?       // session.new
    var workspace: String? // session.new (target ws), session.move (dest ws)
    var text: String?      // session.type
    var select: Bool?      // session.type
    var mode: String?      // split / quick / statusbar: on|off|toggle (show|hide for quick)
}

struct ControlRequest: Codable, Sendable { let cmd: Command; var target: String?; var args: ControlArgs? }

struct ControlSessionNode: Codable, Sendable { let id, name, cwd: String; let active, split: Bool }
struct ControlWorkspaceNode: Codable, Sendable { let id, name: String; let active: Bool; let sessions: [ControlSessionNode] }
struct ControlTree: Codable, Sendable { let workspaces: [ControlWorkspaceNode] }

struct ControlResult: Codable, Sendable { var id: String?; var tree: ControlTree? }
struct ControlResponse: Codable, Sendable { let ok: Bool; var result: ControlResult?; var error: String? }
```

- An unknown `cmd` fails to decode (enum has no matching raw value) → the server catches the
  decode error and replies `{"ok":false,"error":"unknown command: …"}`.

### Target resolver (pure, `agtermCore`)

```
enum TargetResolution: Equatable, Sendable { case resolved(UUID); case notFound; case ambiguous([UUID]) }

enum ControlResolve {
    // candidates = session ids (session commands) or workspace ids (workspace commands)
    static func resolve(_ target: String, candidates: [UUID], active: UUID?) -> TargetResolution
}
```

- `"active"` → `.resolved(active)` or `.notFound` when nil.
- exact `uuidString` (case-insensitive) match → `.resolved`.
- otherwise prefix match on `uuidString.lowercased()`: 1 hit → `.resolved`, 0 → `.notFound`,
  ≥2 → `.ambiguous(hits)`.

### Socket path resolver (pure, `agtermCore`)

```
enum ControlResolve { static func socketPath(stateDir: String?, appSupport: String) -> String }
```

- `stateDir` (the `AGTERM_STATE_DIR` value, if set) → `<stateDir>/agterm.sock`; else
  `<appSupport>/agterm.sock`. Callers pass `appSupport = PersistenceStore.defaultDirectory.path`
  (the public static, `~/Library/Application Support/agterm` — same directory
  `PersistenceStore` writes `workspaces.json`). The app and the CLI both call this with the
  same inputs, so they always rendezvous. (Note: a unix socket path has a ~104-byte length
  limit; the default and `AGTERM_STATE_DIR` temp paths are well under it.)

### `ControlServer` (app target, `@MainActor`)

- POSIX `socket(AF_UNIX, SOCK_STREAM, 0)`; `unlink` any stale path first; `bind`; `chmod`
  `0600`; `listen`. Accept loop on a background `DispatchQueue`; per connection read until
  `\n` (with a **1 MiB max-line cap** — far above any realistic `session.type` payload;
  exceeding it returns an error and closes, never grows the buffer unbounded), decode, hop to
  `@MainActor` to dispatch, encode the response, write, close.
- **`start()` is idempotent** (no-op if already listening) — the scene `.task` can re-run if
  the window is recreated, so a second `start()` must not attempt a second `bind`. `stop()`
  closes the listener and `unlink`s the socket. Lifecycle is deliberately asymmetric: started
  from the scene `.task`, stopped from `AppDelegate.applicationWillTerminate`; a force-quit
  that skips `applicationWillTerminate` leaves a stale socket file, which the next launch's
  `unlink`-first handles.
- Dispatch resolves the target (session-id set or workspace-id set, with the right `active`)
  then calls the backing method. Errors are returned as `{"ok":false,"error":…}`, never
  thrown across the socket; the server never crashes on bad input.
- `session.type`: resolve session → inject text. The only realization step the inject must
  wait for is **surface creation** — once `session.surface != nil` (its backing is non-zero;
  `ghostty_surface_new` has spawned the child pty), `ghostty_surface_text` writes to the pty,
  which the kernel buffers, so text is never lost even before the shell prints its first
  prompt. So:
  - `surface != nil` → `inject(text:)` immediately, return `ok`.
  - `surface == nil` (a never-shown session — surfaces are lazy and defer creation until a
    non-zero backing size, fragile point #4) **with `select:true`** → `selectSession`, then
    poll for `surface != nil` with a **bounded attempt count** (mirror the existing
    `AppActions.focusSplitPane` idiom: 12 × 0.03 s), and inject on the first attempt where the
    surface exists. If it never realizes within the window, return
    `{"ok":false,"error":"session not realized"}` — **never a false `ok`**.
  - `surface == nil` without `select` → immediate `{"ok":false,"error":"session not realized; use select"}`.
  - Headless realization is out of scope. (Decision: the readiness check stays app-side — it
    reads live `GhosttySurfaceView` state; no `agtermCore` predicate, a 1-condition check is not
    worth abstracting.)
- `session.split`: resolve the **target** session and drive `AppStore.toggleSplit(target)` /
  `AppStore.closeSplit(target)` directly (NOT `AppActions.toggleSplit()`, which only acts on
  the active session). Read `args.mode` (`on|off|toggle`) and compute the delta against the
  session's `isSplit` so `on`/`off` are idempotent; then `AppActions.focusSplitPane` for focus.
- `quick` / `statusbar`: read `args.mode` (`show|hide|toggle` for quick; `on|off|toggle` for
  statusbar) and only flip when needed (compute the delta against `isVisible` /
  `statusBarHidden`). An unknown `mode` string → error, not a silent no-op.
- `font.*`: resolve the target surface and call `performBindingAction` on it (targets a
  specific surface, unlike the menu path which only hits the focused one).

### CLI (`agtermctlKit` lib + `agtermctl` exe, `swift-argument-parser`)

- `agtermCore` `Package.swift` gains: the `swift-argument-parser` package dependency; an
  `agtermctlKit` library target (deps: `agtermCore`, `ArgumentParser`) holding the `ParsableCommand`
  tree + the socket client (connect/write/read); an `agtermctl` executable target (thin `main`
  → `agtermctlKit`); an `agtermctlKitTests` test target. **The `agtermCore` library target adds no new
  dependency** — only the CLI targets link `ArgumentParser`.
- `--target` defaults to `active`; `--socket PATH` overrides the resolved path; `--json` emits
  the raw response; `--stdin` (on `session type`) reads the text from stdin. Exit code = 0 on
  `ok`, non-zero otherwise.

## What Goes Where

- **Implementation Steps** (`[ ]`): all code, tests, docs in this repo.
- **Post-Completion** (no checkboxes): manual verification that benefits from a human (real
  scripted workflows, the `--stdin` piping ergonomics).

## Implementation Steps

### Task 1: agtermCore control protocol types + codecs

**Files:**
- Create: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Create: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`

- [x] define `Command` enum, `ControlArgs`, `ControlRequest`, the tree node types
      (`ControlSessionNode`, `ControlWorkspaceNode`, `ControlTree`), `ControlResult`,
      `ControlResponse` — all `Codable, Sendable` per the sketch above
- [x] confirm JSON field names match the wire format (`cmd`, `target`, `args`, `ok`,
      `result`, `error`) — no custom `CodingKeys` unless a name diverges
- [x] write round-trip tests: encode→decode each request variant (tree, every workspace/
      session command, type with/without select, mode-bearing commands) equals the original
- [x] write round-trip tests for responses: ok+id, ok+tree, error
- [x] write a decode test: an unknown `cmd` string fails to decode (drives the server's
      "unknown command" error path)
- [x] run `cd agtermCore && swift test` — must pass before Task 2

### Task 2: agtermCore pure target + socket-path resolvers

**Files:**
- Create: `agtermCore/Sources/agtermCore/ControlResolve.swift`
- Create: `agtermCore/Tests/agtermCoreTests/ControlResolveTests.swift`

- [x] implement `ControlResolve.resolve(_:candidates:active:) -> TargetResolution` (active /
      exact uuid / unique prefix / ambiguous / not-found)
- [x] implement `ControlResolve.socketPath(stateDir:appSupport:) -> String`
- [x] write resolver tests: `active` resolves, `active` with nil → notFound, exact uuid
      (case-insensitive), unique prefix, ambiguous prefix → `.ambiguous` listing hits,
      no-match → notFound, empty candidates
- [x] write path tests: with `stateDir` → `<stateDir>/agterm.sock`; without → `<appSupport>/agterm.sock`
- [x] run `cd agtermCore && swift test` — must pass before Task 3

### Task 3: ControlServer socket skeleton, lifecycle, `tree`, and app wiring

**Files:**
- Create: `agterm/Control/ControlServer.swift`
- Modify: `agterm/agtermApp.swift`
- Create: `agtermUITests/ControlAPIUITests.swift`

- [x] implement `ControlServer` (`@MainActor`): bind a POSIX unix socket at the resolved path
      (unlink stale first, `chmod 0600`), accept loop on a background `DispatchQueue`, read a
      newline-delimited request (1 MiB max-line cap), decode, hop to `@MainActor`, dispatch,
      write the response, close
- [x] make `start()` idempotent (no-op if already listening); `stop()` closes the listener and
      unlinks the socket; a bind failure logs and returns (best-effort, app still launches)
- [x] decode/validation failures (bad JSON, unknown cmd, missing required arg) reply with a
      structured `error`, never crash
- [x] implement the first dispatch arms: `tree` (project `AppStore.workspaces` →
      `ControlTree` with active flags), `session.select`, `workspace.select`
- [x] wire into `agtermApp`: construct `ControlServer(store:actions:)` in `agtermApp.init` (alongside
      `actions`, where `store` already exists — not via the delegate's late-assigned `store`),
      `start()` it in the scene `.task`, `stop()` it from `AppDelegate.applicationWillTerminate`
- [x] add `ControlAPIUITests` with a socket helper (connect, send one line, read one line) and
      a **success** test: launch with `AGTERM_STATE_DIR` + isolated socket, send `tree`, assert
      the seeded workspace/session appear with ids
- [x] add an **error-path** test: a malformed JSON line → `{"ok":false}` with an `error`, and
      the server stays alive (a subsequent `tree` still succeeds)
- [x] run `cd agtermCore && swift test` + `xcodebuild test … -only-testing:agtermUITests/ControlAPIUITests` (Task 3 cases) — must pass before Task 4

➕ **Scope discovered (Task 3):** added an `AGTERM_CONTROL_SOCKET` env override to
`ControlServer.defaultSocketPath()` (takes precedence over the `AGTERM_STATE_DIR`-derived path). The
XCUITest runner is sandboxed: its per-test `AGTERM_STATE_DIR` container path is ~135 bytes (over the
unix-socket `sun_path` ~104-byte limit) and `/tmp` is outside its sandbox grant (connect → EPERM).
The override lets the test bind/connect a short socket inside the runner's own temp dir
(`NSTemporaryDirectory()`, ~81 bytes). The CLI's `--socket` flag (Task 7) is the user-facing
equivalent; the resolver in `agtermCore` is unchanged.

### Task 4: input injection + structural commands

**Files:**
- Modify: `agterm/Ghostty/GhosttySurfaceView.swift`
- Modify: `agterm/Control/ControlServer.swift`
- Modify: `agtermUITests/ControlAPIUITests.swift`

- [x] add `GhosttySurfaceView.inject(text:)` wrapping `ghostty_surface_text(surface, ptr,
      len)` (copy the UTF-8 bytes; no-op when `surface == nil`)
- [x] add dispatch arms: `workspace.new` (returns id), `workspace.rename`, `workspace.delete`
      (honors `canRemoveWorkspace`; returns `cannot delete last workspace` error, no alert),
      `session.new` (returns id; defaults current workspace + `$HOME`), `session.close`,
      `session.rename`, `session.move`
- [x] e2e **success**: `session.new` returns an id and the session appears in
      `workspaces.json`; `session.close` removes the row; `workspace.new`/`rename` reflected
      in json
- [x] e2e **error**: `workspace.delete` of the last workspace returns the keep-one error
      (workspace still present); a command with an unknown `target` returns `no such …`
- [x] run `cd agtermCore && swift test` + the relevant `ControlAPIUITests` cases — must pass before Task 5

### Task 5: `session.type` with surface-realization handling

**Files:**
- Modify: `agterm/Control/ControlServer.swift`
- Modify: `agtermUITests/ControlAPIUITests.swift`

- [x] add the `session.type` dispatch arm: `surface != nil` → `inject(text:)`, return `ok`
- [x] `surface == nil` with `select:true` → `selectSession`, then bounded poll for
      `surface != nil` (12 × 0.03 s, the `focusSplitPane` idiom), inject on first realized
      attempt; if never realized within the window, return `session not realized` (never a
      false `ok`)
- [x] `surface == nil` without `select` → immediate `session not realized; use select` error
- [x] e2e **success**: `session.type "tty > FILE\n"` into the (visible) active session writes
      the tty path to FILE — read it back (the split-test idiom)
- [x] e2e **success**: `session.type --select` into a freshly created, never-shown session
      realizes it and the text lands (assert via the FILE oracle)
- [x] e2e **error**: `session.type` without `select` into a never-shown session returns
      `session not realized`
- [x] run `cd agtermCore && swift test` + the relevant `ControlAPIUITests` cases — must pass before Task 6

### Task 6: control actions — split, quick terminal, font, status bar

**Files:**
- Modify: `agterm/Control/ControlServer.swift`
- Modify: `agterm/Views/QuickTerminal.swift`
- Modify: `agterm/ContentView.swift` (➕ accessibility-id move, see note below)
- Modify: `agtermUITests/ControlAPIUITests.swift`

- [x] add `QuickTerminalController.show()` (set `isVisible = true`) for the `quick show` mode
- [x] add `session.split` dispatch: resolve the **target** id and drive
      `AppStore.toggleSplit(target)` / `closeSplit(target)` directly (NOT the argument-less
      `AppActions.toggleSplit()`); compute the delta vs `isSplit` for `on`/`off`; then
      `AppActions.focusSplitPane`
- [x] add `quick` (show/hide/toggle vs `isVisible`), `font.inc|dec|reset` (resolve target
      surface, `performBindingAction`), `statusbar` (on/off/toggle vs `statusBarHidden`)
- [x] e2e **success**: `statusbar toggle` flips `statusBarHidden` in `workspaces.json`;
      `session.split toggle` shows `split:true` in `tree`/json; `quick toggle` makes the
      `quick-terminal` accessibility element appear; `font.inc` returns `ok`
- [x] e2e **error**: an invalid `mode` (e.g. `statusbar bogus`) returns an error and does NOT
      flip state
- [x] run `cd agtermCore && swift test` + the relevant `ControlAPIUITests` cases — must pass before Task 7

➕ **Scope discovered (Task 6):** the `quick-terminal` accessibility identifier sat on the
Metal-backed `QuickTerminalPane` (an `NSViewRepresentable`), which is NOT exposed in the XCUI
accessibility tree — the `quick toggle` e2e assertion could never find it. Moved the identifier to
the overlay's transparent tap-catcher (`Color.clear`, a real SwiftUI view) with an explicit
`.accessibilityElement()`, in `agterm/ContentView.swift`. Same overlay, queryable element.

### Task 7: agtermctl CLI (agtermctlKit lib + agtermctl executable)

**Files:**
- Modify: `agtermCore/Package.swift`
- Create: `agtermCore/Sources/agtermctlKit/Commands.swift`
- Create: `agtermCore/Sources/agtermctlKit/SocketClient.swift`
- Create: `agtermCore/Sources/agtermctl/main.swift`
- Create: `agtermCore/Tests/agtermctlKitTests/CommandsTests.swift`
- Create: `agtermCore/Tests/agtermctlKitTests/SocketClientTests.swift`

- [x] add the `swift-argument-parser` dependency; add `agtermctlKit` library (deps `agtermCore` +
      `ArgumentParser`), `agtermctl` executable (dep `agtermctlKit`), and `agtermctlKitTests` targets —
      leaving the `agtermCore` **library** target dependency-free
- [x] implement the `ParsableCommand` tree (`Commands.swift`) mirroring the catalog 1:1
      (`tree`, `workspace new|rename|delete|select`, `session new|close|select|rename|move|type|
      split`, `quick`, `font inc|dec|reset`, `statusbar`); each maps args to a `ControlRequest`
- [x] implement `SocketClient.swift`: connect to the resolved path (`--socket` override), write
      `request\n`, read the response line, decode; print human-readable by default, raw with
      `--json`; exit 0 on `ok`, non-zero otherwise; `--target` defaults to `active`; `session
      type` supports `--stdin`
- [x] write `CommandsTests.swift`: each subcommand parses to the expected `ControlRequest`
      (cmd/target/args), incl. an invalid-args error case
- [x] write `SocketClientTests.swift`: round-trip against an in-process stub unix-socket server
      that echoes a canned `ControlResponse`; assert decode + exit-code mapping (ok and error)
- [x] run `cd agtermCore && swift test` (now includes `agtermctlKitTests`) — must pass before Task 8

### Task 8: Verify acceptance criteria

**Files:**
- Modify: `agtermUITests/ControlAPIUITests.swift`

- [x] add the integration coverage NOT already gated per-task: `session.select` by **unique
      prefix** of an id resolves; an **ambiguous-prefix** request returns the `ambiguous` error
      listing candidates; `active` targeting with no explicit id works end-to-end
- [x] verify every catalog command has (1) a `Command` case, (2) a dispatch arm, (3) an
      `agtermctl` subcommand, (4) a test — the keep-in-sync four-point check (all 17 commands pass;
      no gap found — every command has a Command case, a ControlServer dispatch arm, an agtermctl
      subcommand, and a CLI parse test in CommandsTests + protocol/resolver unit coverage)
- [x] run the full gate: `cd agtermCore && swift test` + all `agtermUITests` — must pass before Task 9

### Task 9: Documentation + the keep-in-sync rule

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`
- Modify: `ARCHITECTURE.md`

- [x] add a `CLAUDE.md` "Control API" section: socket path/lifecycle, protocol shape,
      addressing (`active`/UUID/prefix), the command catalog, and the three-layer split
      (`agtermctl` ↔ `ControlServer` ↔ `agtermCore` protocol)
- [x] write the **keep-in-sync convention** into `CLAUDE.md` next to the existing "`AppActions`
      shared by toolbar and menu bar so they never drift" note — extended to the third
      surface, with the four-point definition-of-done
- [x] add a `README.md` "Scripting agterm" subsection (user-facing: build `agtermctl`, examples,
      the never-shown-session `session.type` caveat)
- [x] add an `ARCHITECTURE.md` note for the new module boundary (`agtermctlKit`/`agtermctl` in the
      package; `ControlServer` in the app)
- [x] move this plan to `docs/plans/completed/`

## Post-Completion

*Items that benefit from a human, not blockers:*

**Manual verification:**
- run a real scripted workflow (e.g. spin up a workspace, open three sessions in given
  directories, type a build command into each) and confirm ergonomics.
- confirm `--stdin` piping (`echo 'make test' | agtermctl session type --target work/…  --stdin`)
  and `--json | jq` filtering feel right in practice.
- sanity-check socket permissions (`0600`, owner-only) and that a second app instance failing
  to bind doesn't disrupt the first.

**Future / explicitly deferred (out of v1 scope):**
- `session.key` (synthesized keypresses via `ghostty_surface_key`, with modifiers).
- output/scrollback read and event subscription (would change the transport to a persistent,
  streaming connection — a different design).

---
Smells pre-check: skipped — non-Go project.
