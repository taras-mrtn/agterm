# agt — project notes

`agt` is a native macOS SwiftUI terminal on libghostty, with a two-level workspace -> session vertical sidebar. Read `README.md` for the overview and `ARCHITECTURE.md` for the module split, surface ownership, and the C-boundary concurrency contract before changing the bridge.

## Toolchain

- The app target is generated with `xcodegen` and built with `xcodebuild` (Xcode 26). `mise` is not used; call `xcodegen`, `xcodebuild`, and `swift` directly through the scripts.
- The `agtCore` package is built and tested with `swift test` (Swift 6, strict concurrency `complete`). It is independent of Xcode and libghostty.
- `gh` is required by `scripts/setup.sh` to download release artifacts.

## Build and test commands

- `scripts/setup.sh` — download and extract `GhosttyKit.xcframework` and the ghostty resources. Idempotent; skips work if both are already present.
- `scripts/run.sh` — setup, `xcodegen generate`, `xcodebuild` Debug, then launch.
- `scripts/build.sh` — same but Release, no launch.
- `cd agtCore && swift test` — run the host-free unit tests (`scripts/test.sh` wraps this).

The app must build and `swift test` must stay green after every change.

## GhosttyKit.xcframework

- Source: the `thdxg/ghostty` fork's release artifacts, pinned in `scripts/setup.sh` to tag `build-2026-06-14`. Bump the `TAG` variable deliberately when adopting a newer libghostty.
- `setup.sh` downloads `GhosttyKit.xcframework.tar.gz` and `ghostty-resources.tar.gz` via `gh release download`.
- The xcframework, `agt/Resources/ghostty`, and `agt/Resources/terminfo` are gitignored and never committed. There is no Zig build and no submodule.
- The xcframework is linked with `embed: false` in `project.yml`. Never embed it; embedding breaks the signature on non-Developer-ID builds.

## Module boundary

- `agtCore` must not import GhosttyKit, AppKit, or Metal. Keeping it host-free is what lets `swift test` run with no app host. Model, persistence, and naming logic go here; the surface contract is the `TerminalSurface` protocol, which the app target's `GhosttySurfaceView` conforms to.
- The app target owns all SwiftUI and libghostty code.

## Sidebar

- The sidebar is an AppKit `NSOutlineView` (`WorkspaceSidebar`, an `NSViewRepresentable`), not a SwiftUI `List` — chosen for native cross-workspace drag-and-drop. Its `@MainActor` `Coordinator` is the data source/delegate, backed by `AppStore`. Outline items are cached reference-type `SidebarNode`s, reused across reloads for stable identity (expansion/selection survive `reloadData`).
- Add affordances live in a bottom bar in `ContentView`: a workspace button and a session menu (New Session / Open Directory…). The two session actions are also on each workspace row's right-click menu.
- Accessibility identifiers `session-row`, `workspace-row`, `edit-field`, and `add-session` back the XCUITests. Note the rename field surfaces as a `TextField` for sessions and a `StaticText` for workspaces, so UI tests match `edit-field` by identifier across element types.

## Git integration

- Two git calls per refresh, shelled out (no libgit2): `git -C <cwd> status --porcelain=v2 --branch` (branch, upstream, ahead/behind, dirty entries) and `git -C <cwd> rev-parse --git-dir` (linked-worktree name). A non-zero status exit means the cwd is not a git work tree → `gitStatus = nil` (no sidebar tokens, no title pill).
- `agtCore` stays git-free: `GitStatus` (parser + `compact`/`branchDisplay` formatting) and `GitRefreshPolicy.shouldRefresh` are pure, `Sendable`, and unit-tested with canned strings — never spawning git. The `Process` execution lives in the app target's `GitStatusService`.
- `GitStatusService` is the `@MainActor` orchestrator: throttle state (in-flight set, last-ran cwd/at) is main-actor isolated; git runs off-main in a `Task.detached` worker calling a `nonisolated static` runner (NOT a bare `nonisolated async`, which under Xcode 26 `NonisolatedNonsendingByDefault` would block the main thread). The worker takes only `cwd: String`, returns only `GitStatus?`, and never captures `Session`/`AppStore`/`Process`. The ~2 s timeout is a `DispatchSemaphore` inline on the worker thread; the assignment is equality-gated and stale-cwd-guarded, and a timeout keeps the prior status.
- Refresh triggers: cwd-change via `GhosttySurfaceView.onCwdChange` (wired in `agtApp.makeSurface`), a ~3 s active-session `Task.sleep` loop paused on resign-active, and a selection refresh. The `GitRefreshPolicy` min-interval debounce absorbs OSC-7 floods and launch-time double-fires.

## UI tests

- `agtUITests/` is an XCUITest target that launches the real app and drives the sidebar (rename, close, move, drag, add-session) through the accessibility API — the coverage the host-free `agtCore` unit tests can't provide. Run with `xcodebuild test -project agt.xcodeproj -scheme agt -destination 'platform=macOS'`.
- Tests pass `AGT_STATE_DIR` (a temp dir) via launch environment to isolate persistence; the app honors it in `agtApp.restoredStore()`. The native `Open Directory…` panel is system UI, verified manually rather than in XCUITest.
- **Test cadence**: during iteration run only the relevant target/case (e.g. `xcodebuild test … -only-testing:agtUITests/GitStatusUITests`, or a single method like `…/GitStatusUITests/testCleanShowsNoToken`) — the full suite is ~75 s and needlessly re-runs unaffected tests (the sidebar tests don't change when only the status bar does). Run the complete suite (`cd agtCore && swift test` + all `agtUITests`) only as the pre-commit gate.

## libghostty gotchas

- **terminfo sibling dir.** `GHOSTTY_RESOURCES_DIR` points at `Contents/Resources/ghostty`; libghostty derives `TERMINFO` as `dirname(...)/terminfo` at shell spawn, so the compiled terminfo database must be a sibling at `Contents/Resources/terminfo`. `GhosttyResources` sets only `GHOSTTY_RESOURCES_DIR` and never `TERMINFO` (libghostty overwrites it at spawn). If this layout breaks, `TERM=xterm-ghostty` fails and keys break.
- **Surface lifecycle.** `Session` owns its `GhosttySurfaceView` (`@ObservationIgnored`). The detail pane swaps surfaces via `.id(session.id)`; `dismantleNSView` is a no-op. `ghostty_surface_free` runs only in `destroySurface()` (reached via `teardown()` on close). This single-owner, single-free rule is what makes passing the view as unretained `userdata` safe.
- **Non-zero backing size.** Create the surface only when the view has a non-zero backing size, else the Metal layer renders blank. `pendingSurfaceCreation` defers creation until `setFrameSize` reports a real size.
- **strdup buffer lifetime.** `working_directory` (and `initial_input`) `const char*` buffers must outlive `ghostty_surface_new`; they are held in a `nonisolated(unsafe)` array and freed only in `destroySurface()`.

## C-callback isolation

- `GhosttyCallbacks` is `@unchecked Sendable`, not `@MainActor`. C closures capture nothing and reach Swift via `GhosttyApp.shared`.
- Copy any `char*` into a Swift `String` before hopping; every `@MainActor` touch goes through `DispatchQueue.main.async`.
- `MainActor.assumeIsolated` is allowed only in the `RunLoop.main` timer closure, never in the other callbacks.
- `close_surface_cb` only recovers the view and dispatches to the main actor; it never frees synchronously.

## App icon

- The artwork lives in `agt/Assets.xcassets/AppIcon.appiconset` (full-bleed rounded square, 16–1024). `CFBundleIconName`/`ASSETCATALOG_COMPILER_APPICON_NAME` are both `AppIcon`. Keep it full-bleed (the rounded square fills the canvas, no transparent margin) so the Dock tile matches neighbor apps; an inset/margined source renders visibly smaller.
- **Dock tile is set explicitly at launch.** `AppDelegate.applicationWillFinishLaunching` sets `NSApp.applicationIconImage` because an ad-hoc-signed Debug app launched from DerivedData doesn't forward its bundle icon to the Dock through the usual runtime path (Finder resolves it fine).
- **Load from the asset catalog, not Icon Services.** Use `NSImage(named: "AppIcon")`, NOT `NSWorkspace.shared.icon(forFile:)`. Icon Services caches by bundle path and the DerivedData path is reused across rebuilds, so `icon(forFile:)` serves a stale tile — regenerated artwork never shows. `NSImage(named:)` reads the freshly-compiled `Assets.car` directly.
