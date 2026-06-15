# git integration for agt

## Overview

Surface git status in two places, driven by each session's working directory:

1. **Compact per-session tokens** appended after the name in each sidebar row (`NSOutlineView` cell), **only when the cwd is a git work tree** — ahead/behind arrows plus a dirty indicator, e.g. `myproject   ↑5 ↓2 ●`. Arrows show only when nonzero; `●` (tinted orange) when there are uncommitted changes; nothing when clean and in sync. Dimmed/secondary, smaller; the name truncates first.
2. **Detailed status in the detail pane's title bar**: the window title (left) becomes the active session's pwd name; a trailing toolbar **git pill** (right) shows a branch glyph + branch name (or `detached @ <shortsha>`), `↑N ↓N` (nonzero only), a worktree chip for a linked worktree, and an orange dirty marker when dirty. No git repo → no pill (title is just the name).

This makes the sidebar a quick at-a-glance view of which sessions have local work or divergence, and the title bar a fuller status for the session you're in. Design was brainstormed and validated before this plan.

## Context (from discovery)

- Swift project. Two modules: host-free `agtCore` package (Foundation + Observation only, unit-tested via `swift test`) and the app target (SwiftUI + libghostty + the AppKit `NSOutlineView` sidebar).
- `Session` (`@Observable @MainActor final class`, in `agtCore`) already has `currentCwd` (set by the libghostty PWD callback) and `displayName`. The sidebar is `WorkspaceSidebar` (`NSOutlineView`); `ContentView` hosts it and the detail `TerminalView`.
- The PWD callback path: `GhosttyCallbacks` → `GhosttySurfaceView.applyPwd` → `session.currentCwd = pwd` (on the main actor). This is the natural hook for "refresh git on cwd change".
- `agtUITests/` is an XCUITest target (drives the real app); `AGT_STATE_DIR` isolates test persistence. agtCore tests are deliberately pure/host-free.
- Git is available on the system; `setup.sh`/the app already assume a developer environment.

## Development Approach

- **Testing approach**: code-first, then tests in the same task. The risky logic (parsing git output, formatting tokens, and the refresh/throttle decision) lives in `agtCore` and is **fully unit-tested with fixture strings — never running git**. The app-target pieces (the `Process` invocation, the sidebar/title rendering) are GUI/integration and are **verified by building and running**, matching the project's established split (pure logic unit-tested in `agtCore`; GUI run-verified).
- Complete each task fully before the next. Small, focused changes.
- **Every task that adds testable pure logic MUST add/update `agtCore` tests in the same task.** App-target/GUI tasks have an explicit build-and-run verification instead.
- **Gates after every task**: `cd agtCore && swift test` green; the app builds via `xcodegen generate && xcodebuild … build` with zero strict-concurrency warnings; the existing 7 `agtUITests` stay green; the app launches.

## Testing Strategy

- **Unit tests** (`agtCore`, Swift Testing, git-free): `GitStatus.parse` against fixture `--porcelain=v2 --branch` outputs, the `compact`/detail formatting, AND `GitRefreshPolicy.shouldRefresh` (the throttle/debounce decision lifted out of the `Process` side). These are the core deliverable of Task 1.
- **No git in agtCore tests**: the parser takes a `String` (git's stdout) → `GitStatus`; tests feed canned strings. The throttle decision is pure (`cwd`/timestamps/flags → `Bool`). The `Process` execution itself lives in the app target and is not unit-tested — but its *decision* logic is, via `GitRefreshPolicy`.
- **GUI/service run-verification**: Tasks that touch the service and rendering are verified by launching the app in a git repo and observing the tokens/pill. The Task 4/5 a11y hooks (`git-compact`, `git-pill`) exist so the rendering is assertable, since the project has shipped silent SwiftUI/AppKit wiring bugs before (the rename bug that motivated `agtUITests`).
- **Stretch XCUITest** (optional, Post-Completion): seed a session pointing at a temp `git init`'d repo by **pre-writing a `workspaces.json` into `AGT_STATE_DIR`** with the session's `initialCwd` set to the temp repo (the existing harness only points `AGT_STATE_DIR` at an empty dir; the Open-Directory native panel can't be driven by XCUITest — `SidebarUITests` only confirms the picker appears). Gate it with `XCTSkipUnless(gitAvailable)` so it skips cleanly where git is absent, rather than being omitted.

## Progress Tracking

- Mark completed items `[x]` immediately. New tasks get a ➕ prefix; blockers get ⚠️. Keep this file in sync.

## Solution Overview

```
agtCore (pure, host-free)
 ├─ GitStatus            Equatable, Sendable value type
 │    { branch?, detachedSHA?, upstream?, ahead, behind, dirty, worktree? }
 │    .parse(porcelainV2:gitDir:) -> GitStatus      // pure string → value (total, never nil)
 │    .compact: String                              // sidebar tokens ("↑5 ↓2 ●")
 │    (detail accessors for the pill)
 ├─ GitRefreshPolicy     pure decision: shouldRefresh(cwd:lastRanCwd:lastRanAt:now:inFlight:)
 │    -> Bool            // the OSC-7-flood debounce / coalesce predicate, table-tested
 └─ Session.gitStatus    @Observable var gitStatus: GitStatus?

app target
 ├─ GitStatusService     @MainActor orchestrator. runs the two `git` calls OFF-main via
 │    Task.detached (or @concurrent), ~2s timeout, parses via agtCore, and hops back to
 │    @MainActor to set session.gitStatus (equality-gated). throttle/in-flight/last-cwd
 │    state is @MainActor; the worker gets only `cwd: String`, returns only `GitStatus?`.
 │    triggers: cwd-change (PWD path, debounced via GitRefreshPolicy), selection/active,
 │    ~3s active refresh loop (paused when not frontmost), NSApplication.didBecomeActive.
 ├─ WorkspaceSidebar     session cell: a 2nd trailing dimmed label = gitStatus?.compact
 │    (name truncates first); targeted row reload on a gitStatus-only delta.
 └─ ContentView          NSWindow.title = active.displayName + trailing .toolbar GitStatusPill
```

Key decisions (validated in brainstorm):
- **Shell out to git**, no libgit2. Two cheap calls per refresh: `git -C <cwd> status --porcelain=v2 --branch` (branch, upstream, ahead/behind, dirty entries) and `git -C <cwd> rev-parse --git-dir` (worktree name from a `/worktrees/<name>` path). Status call non-zero exit → `gitStatus = nil` (the "only if git controlled" gate, free).
- **Refresh**: active session live (~3s `Task.sleep` loop + on focus, paused when app not frontmost); every session on cwd-change and on becoming active; background sessions not polled; per-session throttle/coalesce; ~2s git timeout.
- **agtCore stays pure** (no `Process`); the parser, formatting, and refresh-policy decision are the unit-tested core. The `Process` glue and rendering are app-target.

## Technical Details

### `git status --porcelain=v2 --branch` parsing

Header lines to read:
- `# branch.head <name>` → `branch`. When the value is literally `(detached)`, leave `branch = nil` and set `detachedSHA` from `# branch.oid <sha>` (short-formed). Invariant: `branch == nil ⟺ detachedSHA != nil` — exactly one is set.
- **Unborn branch / initial commit:** a fresh repo with no commits emits `# branch.oid (initial)` and a normal `# branch.head <name>`. `(initial)` is **not** a detached SHA — it must leave `detachedSHA = nil` and keep `branch = <name>`. Only the literal `(detached)` head value sets `detachedSHA`.
- `# branch.upstream <name>` → `upstream` (absent when no upstream).
- `# branch.ab +<ahead> -<behind>` → `ahead`, `behind`. Porcelain v2 always emits both signs and **behind is the negatively-signed token** (`-2`); the parser strips the sign and stores `abs` (never a negative `behind`). The line is **absent when there is no upstream** → `ahead = 0, behind = 0`, and that absence must NOT be treated as non-git.

Entry lines (anything not starting with `#`): `1 …` (changed), `2 …` (renamed/copied), `u …` (unmerged), `? …` (untracked). `dirty` = count of these entries (tracked changes + untracked). Clean repo → `dirty == 0` and no entry lines. **Counting caveat:** a `2 …` (rename/copy) line ends with `<path><sep><origPath>` (two paths, tab-separated under `-z`-less output) and has a different field layout than `1 …`; the parser counts one entry per non-`#` line by its **leading token** (`1`/`2`/`u`/`?`), so it must not be confused by the embedded paths/spaces. `dirty` is the line count, regardless of per-line field shape.

### worktree detection

`git -C <cwd> rev-parse --git-dir` → the output may be relative (`.git`) or absolute. A linked worktree's git-dir has the form `…/worktrees/<name>`; detect by matching the **trailing** `worktrees/<name>` segment (not a bare `contains`, so a path that merely includes the substring elsewhere can't false-positive) and take `<name>`. Anything else (e.g. ending in `.git`) → `worktree = nil` (main work tree). One extra cheap call; ≤ 2 git invocations per refresh.

### `GitStatus` formatting

- `compact` (sidebar): `↑<ahead>` if ahead>0, `↓<behind>` if behind>0, `●` if dirty>0, space-joined; empty string when clean and in sync. (No branch name in the compact form — the row already shows the session name.)
- detail (pill): branch (or `detached @ <shortsha>`), `↑N`/`↓N` when nonzero, worktree chip when `worktree != nil`, dirty marker/count when `dirty>0`. Rendering/styling lives in the SwiftUI pill view; `agtCore` exposes the raw fields + small helpers, not SwiftUI.

### Concurrency (Swift 6 strict `complete`)

- `GitStatus` (and `GitRefreshPolicy`) are `Sendable` value types → safe to compute off-main and hand to the main actor. `GitStatus` must stay all-value/`Sendable` members — adding a reference/closure property breaks the whole cross-actor design at compile time.
- **Off-main mechanism is pinned, not "a nonisolated path":** the worker runs in `Task.detached { … }` (its body has no actor isolation) calling a `nonisolated static` git-runner, OR a `@concurrent` async method. A **bare `nonisolated func … async` is NOT sufficient** — under Xcode 26's `NonisolatedNonsendingByDefault` it runs on the *caller's* executor (the main actor), so the git `Process` would block the main thread. The worker takes only `cwd: String` and returns only `GitStatus?`.
- **`Process`/`Pipe` are non-`Sendable` and are created, run, and consumed entirely inside the one worker closure** — never captured across a hop. The ~2s timeout is done **inline on the worker thread**: signal a `DispatchSemaphore` from `process.terminationHandler`, `semaphore.wait(timeout: .now() + 2)`, and on timeout call `process.terminate()` from that same closure (same thread that owns the `Process`). A `Timer`/`asyncAfter` that captures the `Process` to kill it would not compile under `complete` (or force `@unchecked`). The blocking semaphore is acceptable precisely because this is a deliberately-blocking detached worker, not an actor-isolated async context.
- **Pipe-drain order prevents deadlock:** `git status --porcelain=v2` on a large dirty tree can exceed the 64 KB pipe buffer, so the worker calls `pipe.fileHandleForReading.readDataToEndOfFile()` **first** (drains to EOF when git closes the fd on exit) and **then** `process.waitUntilExit()`. No second context shares the `Pipe`.
- After the worker returns, hop to `@MainActor`, look the session up by `id`, and assign. **Three guards on the assignment:** (1) skip if the session's *current* `currentCwd` no longer equals the `cwd` the worker ran for (stale-result clobber — a `cd a; cd b` race where A finishes after B; discard and re-enqueue for the latest cwd); (2) **equality-gate** the write (`if session.gitStatus != newValue`) — `@Observable` invalidates on *every* write regardless of value, so an un-gated 3s tick writing an identical status would storm the sidebar reload + toolbar re-eval; (3) a timeout/transient failure keeps the previous `gitStatus` (never clobbers to `nil`).
- `Session`/`AppStore` stay `@MainActor` (not made `Sendable`). **All throttle state — in-flight `Set<UUID>`, last-ran-cwd `[UUID: String]`, last-ran-at `[UUID: Date]` — are `@MainActor`-isolated fields of `GitStatusService`, read/written only on the main actor** (before spawning the worker and again on the completion hop). The worker never touches them. The spawn/skip decision uses the pure `GitRefreshPolicy.shouldRefresh(...)` from agtCore.

## What Goes Where

- **Implementation Steps** (`[ ]`): the `GitStatus` type/parser/tests, the `Session` field, the service, the two render surfaces, the trigger wiring, and docs.
- **Post-Completion** (no checkboxes): manual verification scenarios (a real repo: edit a file → dirty dot; commit → ahead; a linked worktree → chip; a non-git dir → no tokens), and the optional stretch XCUITest.

## Implementation Steps

### Task 1: `GitStatus` + `GitRefreshPolicy` value types + parser + formatting (agtCore)

**Files:**
- Create: `agtCore/Sources/agtCore/GitStatus.swift`
- Create: `agtCore/Sources/agtCore/GitRefreshPolicy.swift`
- Create: `agtCore/Tests/agtCoreTests/GitStatusTests.swift`
- Create: `agtCore/Tests/agtCoreTests/GitRefreshPolicyTests.swift`

**Design Contract:**
- `GitStatus` (exported — the app target and `Session` reference it): `struct GitStatus: Equatable, Sendable { var branch: String?; var detachedSHA: String?; var upstream: String?; var ahead: Int; var behind: Int; var dirty: Int; var worktree: String? }`. Members must stay value/`Sendable` (the cross-actor design in Task 3 depends on it).
- `static func parse(porcelainV2 output: String, gitDir: String?) -> GitStatus` — **non-optional**, pure, total (never throws). The "is this a repo?" decision lives in the service (a non-zero git exit → `gitStatus = nil`), not in `parse`; `parse` is only ever called with real status output. (Resolves the earlier diagram/contract mismatch — the signature is non-optional everywhere.)
- `var compact: String` — sidebar tokens (empty when clean+synced).
- Small detail helpers as needed (e.g. `var branchDisplay: String` → branch or `detached @ <shortsha>`); keep SwiftUI out of `agtCore`.
- `GitRefreshPolicy`: a pure, `Sendable` decision helper — `static func shouldRefresh(cwd: String, lastRanCwd: String?, lastRanAt: Date?, now: Date, minInterval: TimeInterval, inFlight: Bool) -> Bool`. Encodes the OSC-7-flood debounce: `false` if a refresh for that session is in flight; `false` if `cwd == lastRanCwd` AND within `minInterval` of `lastRanAt`; `true` for a new cwd, or for the same cwd once `minInterval` has elapsed (active-timer poll). This is the genuinely risky throttle logic, lifted out of the `Process` side so it can be unit-tested without git.

- [ ] add `GitStatus` value type and `parse(porcelainV2:gitDir:)` per Technical Details (header + entry lines; worktree from `gitDir`; `(initial)` is not a detached SHA; count entries by leading token)
- [ ] add `compact` and the detail helpers (`branchDisplay`, ahead/behind/worktree/dirty accessors for the pill)
- [ ] add `GitRefreshPolicy.shouldRefresh(...)` per the contract above
- [ ] write `GitStatusTests` parse fixtures — **clean+in-sync**; **ahead-only**; **behind-only**; **ahead+behind**; **dirty: mixed entries** (`1 …` modified + `2 …` rename + `u …` unmerged + `? …` untracked, asserting an exact `dirty` integer); **no upstream** (no `branch.ab` line → `ahead==0, behind==0`, still a repo); **detached HEAD** (asserts `branch==nil && detachedSHA!=nil` AND `ahead==0 && behind==0`); **initial commit / unborn branch** (`# branch.oid (initial)` → `branch!=nil, detachedSHA==nil`); **linked-worktree `gitDir`** (`…/worktrees/<name>` → `worktree=="<name>"`); **main-worktree `gitDir`** (ends in `.git` → `worktree==nil`)
- [ ] write `GitStatusTests` formatting cases (prefer a `@Test(arguments:)` table asserting literal output): `compact==""` when clean+synced; `"↑5"` ahead-only; `"↓2"` behind-only; `"●"` dirty-only; `"↑5 ↓2 ●"` full combo (single-space separator, fixed order); plus `behind` parsed positive (sign stripped) and detached `branchDisplay` rendering
- [ ] write `GitRefreshPolicyTests` (`@Test(arguments:)` table): in-flight → false; same-cwd within min-interval → false; same-cwd after min-interval → true; new cwd → true; `cd a; cd b` coalesces to the latest cwd
- [ ] run `swift test` — must pass before next task

### Task 2: `Session.gitStatus` (agtCore)

**Files:**
- Modify: `agtCore/Sources/agtCore/Session.swift`
- Modify: `agtCore/Tests/agtCoreTests/SessionTests.swift`

- [ ] add observed `var gitStatus: GitStatus?` to `Session` (defaults nil; `@MainActor`, observed so the sidebar/pill react). No `GitStatusProviding` protocol — the app's `GitStatusService` sets the field directly; a single-implementer protocol with no agtCore consumer would be dead abstraction.
- [ ] write/extend `SessionTests`: round-trip (`session.gitStatus = x; #expect(session.gitStatus == x)`, and `nil` default) and that `displayName` is independent of `gitStatus`. Match the suite's existing derived-value style — don't introduce a `withObservationTracking` harness just to assert "observable"; the macro tracks `gitStatus` like `currentCwd` already does, and the live re-render is covered by the Task 4/5 run-verification
- [ ] run `swift test` — must pass before next task

### Task 3: `GitStatusService` — off-main git + parse + throttle (app target)

**Files:**
- Create: `agt/Git/GitStatusService.swift`
- Modify: `agt/agtApp.swift` (own the service; refresh the active session on selection so it's observable)

- [ ] implement `GitStatusService` (`@MainActor` orchestrator). Strict-concurrency boundary: on `@MainActor` read the session's `id` + `currentCwd` (copy the `String` out); spawn the worker via **`Task.detached`** (calling a `nonisolated static` runner) or a **`@concurrent`** method — NOT a bare `nonisolated async` (which runs on the main executor under Xcode 26 `NonisolatedNonsendingByDefault`). The worker takes only `cwd: String`, runs the two git calls, and returns a `Sendable GitStatus?`; hop back to `@MainActor`, look the session up by `id`, and assign. NEVER capture `Session`, `AppStore`, or `Process` across the hop. Non-zero status exit → `nil`. Parse via `agtCore` `GitStatus.parse`
- [ ] `Process` timeout (~2s) done **inline on the worker thread** (no cross-context capture of the non-`Sendable` `Process`): create/run/consume the `Process` + `Pipe` in one closure; signal a `DispatchSemaphore` from `process.terminationHandler`, `wait(timeout: .now() + 2)`, and on timeout call `process.terminate()` from that same closure. Pipe order: `readDataToEndOfFile()` **then** `waitUntilExit()` (drains before waiting, so a large dirty tree can't deadlock on the 64 KB buffer)
- [ ] completion-hop guards on the `@MainActor` assignment: (1) skip if the session's current `currentCwd` ≠ the `cwd` the worker ran for (stale-result clobber / coalesce-to-latest → re-enqueue for the latest cwd); (2) **equality-gate** `if session.gitStatus != newValue` before assigning (stops the 3s-tick reload/toolbar storm); (3) a timeout/transient failure keeps the previous `gitStatus` (never clobbers to `nil`)
- [ ] per-session throttle state lives on the `@MainActor` service — in-flight `Set<UUID>`, last-ran-cwd `[UUID:String]`, last-ran-at `[UUID:Date]`, read/written only on the main actor; the spawn/skip decision calls `agtCore` `GitRefreshPolicy.shouldRefresh(...)`. The worker never touches this state
- [ ] wire a refresh when a session becomes selected/active (so the result is observable now)
- [ ] **run-verification** (no unit tests — `Process`/git glue; the throttle *decision* is unit-tested via `GitRefreshPolicy` in Task 1): launch in a git repo, select a session, confirm via logging that `gitStatus` is populated (branch/ahead/behind/dirty correct) and that a non-git cwd yields nil; build clean, zero strict-concurrency warnings
- [ ] `swift test` still green (agtCore unaffected)

### Task 4: Sidebar compact tokens (app target)

**Files:**
- Modify: `agt/Views/WorkspaceSidebar.swift`

- [ ] redesign the session cell as **two labels**, not "add a label": the existing name `NSTextField` plus a new trailing token `NSTextField`. Re-constrain the name's trailing to the token's leading; set content-hugging low / compression-resistance low on the name and high on the token so **the name truncates first** (`.byTruncatingTail`) while the tokens stay whole. `makeCell` builds both; `viewFor` must **reset the token field on reuse** (a recycled cell carries the prior session's tokens), same as it already resets the name field's editing state
- [ ] token content = `session.gitStatus?.compact`. Use an `NSAttributedString` (a single `stringValue` can't be two colors): `↑N ↓N` runs in `secondaryLabelColor`, the `●` run in `NSColor.systemOrange` (selection-aware; verify it survives the `.sourceList` emphasized/selected row). Smaller font (e.g. `.preferredFont(forTextStyle: .caption1)`)
- [ ] when `compact == ""` (clean+synced) or `gitStatus == nil` (non-git), hide the token field / collapse its width so the name reclaims the full row and isn't pre-truncated
- [ ] register observation in `updateNSView`'s read: fold each session's `gitStatus` into the existing `store.workspaces.map { … }` tuple (e.g. add `$0.sessions.map { ($0.id, $0.gitStatus) }`) so a `gitStatus` change re-invokes `updateNSView`. A touch only inside `viewFor` will NOT trigger the re-invoke
- [ ] **targeted reload, not the full `rebuildAndReload()`**: when the change is `gitStatus`-only (tree ids unchanged), reload just the affected session rows via `outline.reloadItem(node)` (coordinator caches last-seen `gitStatus` per id to find the delta), and **skip while `committing`/editing** so a 3s tick can't drop an in-progress rename. The existing full rebuild stays for structural changes (add/move/close/rename)
- [ ] add an accessibility hook so the tokens are assertable later: set the row/token `accessibilityValue` to `compact` (or a `git-compact` element). Keep the `session-row` identifier on the name. (This is what makes the Post-Completion stretch XCUITest writable; "decorative, no a11y" would permanently block it)
- [ ] **run-verification**: in a git repo, the selected session's row shows `↑/↓/●` matching reality; a non-git session shows none; renaming a row while the timer ticks is not interrupted; build clean
- [ ] `swift test` green; existing `agtUITests` (7) still pass

### Task 5: Title pill (app target)

**Files:**
- Modify: `agt/ContentView.swift`
- Create: `agt/Views/GitStatusPill.swift`

- [ ] **window title: drive `NSWindow.title` directly — this is the primary path, not a fallback.** The scene is `Window("agt", id: "main")` (a fixed string literal owns the titlebar; verified `agtApp.swift:13`), so `.navigationTitle` on the `NavigationSplitView` detail does NOT reliably override it. Use a small `WindowAccessor` (`NSViewRepresentable` reading `view.window`, deferred via `DispatchQueue.main.async` since the window is nil at make time) and set `window.title = store.activeSession?.displayName ?? "agt"`, updated on change. (`.navigationTitle` may be set too, but it is not load-bearing.)
- [ ] **pin the toolbar host:** attach `.toolbar { ToolbarItem(placement: .primaryAction) { GitStatusPill(status: store.activeSession?.gitStatus) } }` on a node present in **both** detail branches (the `NavigationSplitView` itself, or a container that wraps both the `TerminalView` and the `Text("No session selected")` branch) — not inside the `if let active` branch, which vanishes when nothing is selected. Confirm the `Window` shows a standard titlebar that hosts the item
- [ ] add `GitStatusPill` (SwiftUI): branch glyph (`arrow.triangle.branch`) + `branchDisplay`, `↑N ↓N` (nonzero only), a worktree chip when `worktree != nil`, an orange dirty marker when `dirty>0`; subtle capsule, `.caption`. `nil` status → render nothing (no pill). Set `accessibilityIdentifier("git-pill")` + `accessibilityValue(branchDisplay)` so the pill is assertable later
- [ ] **run-verification**: the titlebar shows the session name with the pill on the right; editing a file in the **already-selected** session updates the pill **without re-selecting** (confirms the `store.activeSession?.gitStatus` dependency re-evaluates the toolbar, not just on selection change); no repo → no pill; switching sessions updates both; build clean
- [ ] `swift test` green; `agtUITests` (7) still pass

### Task 6: Refresh triggers + polish (app target)

**Files:**
- Modify: `agt/Git/GitStatusService.swift`
- Modify: `agt/Ghostty/GhosttySurfaceView.swift` — add an `onCwdChange` closure, invoked from `applyPwd`
- Modify: `agt/agtApp.swift` (active refresh loop + focus observers; wire `onCwdChange` in `makeSurface`)

- [ ] hook cwd-change with a **named injection path** (`applyPwd` sets `session.currentCwd` directly and must not learn about the service): add an `onCwdChange` closure to `GhosttySurfaceView` (parallel to the existing `onExit`), set in `agtApp.makeSurface`, and invoke it from `applyPwd` after assigning `currentCwd`. The closure calls `service.requestRefresh(sessionID:)`. The **debounce is the `GitRefreshPolicy` decision on the `@MainActor` service** (last-ran-cwd dedup + min-interval from Task 3): a prompt redraw re-reporting the same cwd must not spawn git; `cd a; cd b` coalesces to one run against the latest cwd
- [ ] active-session refresh as a **`Task { @MainActor in while !Task.isCancelled { try? await Task.sleep(for: .seconds(3)); refreshActive() } }`** loop (not `Timer` — avoids a second `MainActor.assumeIsolated` site; ARCHITECTURE keeps `assumeIsolated` to the one RunLoop tick). Store the `Task` handle on the `@MainActor` service; **cancel it** on `NSApplication.didResignActiveNotification`; on `didBecomeActiveNotification` recreate the loop AND do one immediate refresh — a single observer pair (don't also register a separate didBecomeActive refresh)
- [ ] observer/lifetime discipline: capture `[weak self]` (or `[weak store]`) in the loop and the notification closures; `addObserver(forName:object:queue: .main)` closures are `@Sendable`, not statically `@MainActor`, so reach the service via `Task { @MainActor in … }`/`DispatchQueue.main.async` (the codebase convention) — **not** `assumeIsolated`; retain the returned observer tokens and remove them on teardown
- [ ] confirm background sessions are refreshed only on cwd-change and selection (no polling), the throttle prevents overlap, and a launch-time double-fire (selection refresh + first `didBecomeActive`) is absorbed by the `GitRefreshPolicy` min-interval
- [ ] **run-verification**: edit a file in the active session → `●` appears within ~3s; `cd` into another repo → tokens update; background the app → no git activity (loop cancelled); switch sessions → the new one refreshes; build clean
- [ ] `swift test` green; `agtUITests` (7) still pass

### Task 7: Verify acceptance + docs

- [ ] verify all Overview requirements: compact sidebar tokens (git-only), title name + pill, ahead/behind + dirty + worktree + detached, refresh model, non-git → nothing
- [ ] full gates: `cd agtCore && swift test` green; clean app build (zero strict-concurrency warnings); `agtUITests` (7) green
- [ ] update `README.md` (Features: git status in sidebar + title), `ARCHITECTURE.md` (the `agtCore` `GitStatus` + the app `GitStatusService` + refresh model), `CLAUDE.md` (git integration notes: the two git calls, the refresh/throttle model, agtCore-stays-git-free)
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

*No checkboxes — manual/external.*

**Manual verification scenarios:**
- Edit a tracked file in the active session → orange `●` appears in the row and pill within ~3s; revert → it clears.
- Make a local commit ahead of upstream → `↑1`; `git fetch` behind → `↓N`.
- Open a session in a **linked worktree** (`git worktree add`) → the pill shows the worktree chip.
- Detached HEAD (`git checkout <sha>`) → pill shows `detached @ <shortsha>`, no ahead/behind.
- A non-git directory → no tokens, no pill (title is just the name).
- Background the app for a while → no repeated git processes (refresh loop cancelled); foreground → refreshes.

**Optional (stretch):** an `agtUITests` test that **pre-writes a `workspaces.json` into `AGT_STATE_DIR`** with a session whose `initialCwd` is a temp `git init`'d repo containing a dirty file, launches, and asserts the sidebar `git-compact` value / `git-pill` shows `●` (via the Task 4/5 a11y hooks). Do NOT route through the Open-Directory panel — it's system UI XCUITest can't drive (see `SidebarUITests.testOpenDirectoryShowsPicker`). Gate with `XCTSkipUnless(gitAvailable)`. Kept optional so the required gates don't depend on git being installed.

---
Smells pre-check: skipped — non-Go project (Swift).
