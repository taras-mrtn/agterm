# Settings Window — Phase 1 (Appearance: font, size, theme)

## Overview
- Add a standard macOS Settings window (Cmd+,) to agterm, with three tabs: **General**, **Appearance**, **Key Mapping**. Only **Appearance** is populated in phase 1; General and Key Mapping are placeholder/stub tabs.
- Appearance phase 1 controls: terminal **font family**, default terminal **font size**, and ghostty **theme** selection.
- Settings persist to a dedicated file and apply **live** to running terminals (no shell loss) via ghostty's `update_config`.
- This is phase 1 of an evolving feature; later phases fill General and Key Mapping.

## Context (from discovery)
- Files/components involved:
  - `agtermCore/Sources/agtermCore/` — host-free model + persistence (new: `AppSettings`, `SettingsStore`).
  - `agterm/Ghostty/GhosttyApp.swift` — builds the ghostty config (`loadConfig`: `config_new` → bundled `ghostty-defaults.conf` → user `~/.config/ghostty/config` → `load_recursive_files` → `finalize`). The agterm settings file slots in here, loaded last so the UI wins.
  - `agterm/agtermApp.swift` — App scene; add a `Settings { … }` scene; load settings at launch (honor `AGTERM_STATE_DIR`).
  - `agterm/agtermApp.swift` `makeSurface`/`makeSplitSurface`, `agterm/Views/QuickTerminal.swift` — surfaces that must receive `ghostty_surface_update_config` on a live apply.
  - `agterm/Resources/ghostty/themes/` — 512 theme files (names like `3024 Night`, `Adwaita Dark`) shipped by ghostty; enumerate for the theme picker.
- Related patterns:
  - Persistence: `PersistenceStore` (JSON load/save, injectable directory, corrupt/missing → default) at `~/Library/Application Support/agterm/`, with `AGTERM_STATE_DIR` override for tests. `AppSettings`/`SettingsStore` mirror this exactly.
  - `Snapshot` value types: `Codable, Equatable, Sendable`, optional fields for forward-compat (a field added later still decodes old files). `AppSettings` follows the same.
  - Per-session font size already exists: `Session.fontSize` (cmd +/- override), applied at surface creation and persisted. The new app-wide default is the base for sessions WITHOUT an override.
- Dependencies/APIs:
  - ghostty config: no direct set API; values come from a config FILE via `ghostty_config_load_file`. Build with `ghostty_config_new` → load files → `ghostty_config_finalize`.
  - Live apply: `ghostty_app_update_config(app, cfg)` + `ghostty_surface_update_config(surface, cfg)` push a rebuilt config to existing surfaces — shells survive.
  - Theme: set `theme = <name>` in the config file. Font: `font-family = <name>`, `font-size = <n>`.

## Development Approach
- **Testing approach**: Regular (code first, then tests).
- Complete each task fully before the next; small, focused changes.
- **Every task includes its tests** — agtermCore unit tests for host-free model/persistence; XCUITest for observable UI behavior (drive Settings, assert via the persisted `settings.json`).
- **All tests pass before the next task.** The app must build and `swift test` must stay green after every change.
- Update this plan when scope changes.
- Maintain backward compatibility (optional settings fields; missing file → defaults).

## Testing Strategy
- **Unit tests (agtermCore, host-free)**: `AppSettings` round-trip + optional-field decode; `SettingsStore` load/save/corrupt/missing/missing-dir.
- **XCUITest (agterm)**: open Settings via the app menu, change theme / font size / font family in Appearance, and assert the value lands in the hermetic `settings.json` (file oracle, like `StatusBarMenuUITests`/`FontSizeUITests`). Live application to the Metal surface is verified manually (the accessibility tree can't read terminal rendering).
- Run the complete suite (`cd agtermCore && swift test` + all `agtermUITests`) as the pre-commit gate.

## Progress Tracking
- Mark completed items `[x]` immediately. Add discovered tasks with ➕, blockers with ⚠️. Keep the plan in sync.

## Solution Overview
- **Model (agtermCore)**: `AppSettings` (Codable value type, optional `fontFamily`/`fontSize`/`theme`; nil = ghostty default) + `SettingsStore` (JSON at `<dir>/settings.json`, injectable dir). Host-free and unit-tested.
- **Observable wrapper (app)**: `@Observable @MainActor SettingsModel` holds the loaded `AppSettings`, exposes bindings for the UI, and on every change: saves via `SettingsStore` AND triggers a live ghostty apply.
- **Ghostty application (app)**: `AppSettings` is serialized to a ghostty config file (`<dir>/ghostty-settings.conf`) with the `font-family`/`font-size`/`theme` lines for whichever are set. `GhosttyApp.loadConfig` loads it **last** (UI overrides the user's ghostty config). A live apply rebuilds the config and broadcasts `ghostty_app_update_config` + `ghostty_surface_update_config` to every live surface (primary, split, quick terminal).
- **Enumeration (app)**: themes = sorted contents of the bundle `ghostty/themes` dir; fonts = monospaced family names via `NSFontManager`.
- **UI (app)**: `Settings { SettingsView() }` scene; `SettingsView` is a `TabView` with General (stub), Appearance (font-family picker, font-size stepper/field, theme picker), Key Mapping (stub).
- **Font-size reconciliation (user-approved, simplest)**: cmd +/- still sets a per-session size at runtime (`Session.fontSize`). But applying an appearance change in Settings **resets all terminals to the new default and clears the per-session overrides** (`Session.fontSize → nil`), so the shared `update_config` broadcast stays consistent and there is no per-surface config or zoom-preservation machinery.

## Technical Details
- `AppSettings` (agtermCore): `Codable, Equatable, Sendable`. Fields: `var fontFamily: String?`, `var fontSize: Double?`, `var theme: String?` (nil = ghostty default). All fields optional, so an older `settings.json` (missing a field added later) still decodes — that IS the forward-compat mechanism. No `version` field: with all-optional fields a version bump would only add a discard-on-mismatch path that wipes the user's settings, the opposite of what optional fields buy.
- `AppSettings.ghosttyConfigLines() -> [String]` (agtermCore, pure): the ghostty config lines for the set fields (`font-family = …`, `font-size = …`, `theme = …`). Values are written RAW (no quotes) — ghostty takes the whole line remainder as the value, confirmed against the bundled conf + theme files (`palette = 0=#…`), so names with spaces (`3024 Night`) must NOT be quoted. Host-free and unit-tested; the app target writes these lines to the conf file.
- `SettingsStore` (agtermCore): mirrors `PersistenceStore` — `init(directory:)`, `load() -> AppSettings` (missing/corrupt → `AppSettings()`), `save(_:) throws`. File: `<directory>/settings.json`.
- Settings file location: same directory as `workspaces.json` (the `AGTERM_STATE_DIR` override applies, so XCUITests are hermetic).
- ghostty settings file: `<directory>/ghostty-settings.conf`, written from `AppSettings` (only lines for set fields). `GhosttyApp.loadConfig` loads it after the user config (UI wins). Quote values containing spaces per ghostty config syntax (theme/font names have spaces).
- Live apply (a `ConfigApplier`-style coordinator, app target): write `ghostty-settings.conf`, build ONE fresh `ghostty_config_t` via `loadConfig` (carrying theme + font-family + the default `font-size`), call `ghostty_app_update_config(app, cfg)`, then call `ghostty_surface_update_config(surface, cfg)` on every live surface. ONE shared config for all surfaces — `update_config` re-applies the whole config (including `font-size`), so every terminal resets to the new default size; that's the user-approved behavior, which is why no per-surface config is needed.
- **Reset per-session zoom on apply**: because the shared `update_config` resets every surface to the default size, also clear `Session.fontSize → nil` for all sessions on a settings apply, so the persisted/runtime state stays consistent with what's on screen (a later surface recreation won't resurrect a stale zoom).
- **Surface exposure (the broadcast needs to reach the raw surface)**: `Session.surface`/`splitSurface` are typed `(any TerminalSurface)?` and `TerminalSurface` exposes only `teardown()`; the raw `ghostty_surface_t` is `private(set)` on `GhosttySurfaceView`. So the applier reaches surfaces by downcasting to `GhosttySurfaceView` (app target) and calling a new method there (e.g. `applyConfig(_ cfg: ghostty_config_t)` → `ghostty_surface_update_config`). The quick terminal's surface is held privately in `QuickTerminalController` and only reachable via `surface()` which CREATES one — add a non-creating accessor (e.g. `currentSurface() -> GhosttySurfaceView?`) so the broadcast doesn't spawn a shell.
- ⚠️ **Config ownership (resolve first, before the broadcast)**: the header has no ownership docs on `update_config`, and the existing `loadConfig` keeps `self.config` alive for the app's lifetime (never freed except the error path) — there is no free-after-update precedent. Determine whether `update_config` copies or takes ownership (read upstream ghostty source or test one apply under Instruments). Likely model for agterm's single long-lived config: swap `self.config` to the new one and free the PREVIOUS config after the broadcast — confirm before wiring the broadcast.
- Font enumeration: `NSFontManager.shared` / `NSFontManager.shared.availableFontFamilies` filtered to fixed-pitch (e.g. via `NSFont(name:size:)?.fontDescriptor.symbolicTraits.contains(.monoSpace)` or `availableMembers(ofFontFamily:)`), sorted. Store the family name string; nil = ghostty default.
- Theme enumeration: `Bundle.main.url(forResource: "ghostty", withExtension: nil)` → `themes/` dir contents, names sorted case-insensitively. Store the theme name string; nil = ghostty default.
- Settings scene tabs: `TabView { GeneralSettingsView().tabItem { Label("General", systemImage: "gear") }; AppearanceSettingsView(...).tabItem { Label("Appearance", systemImage: "paintbrush") }; KeyMappingSettingsView().tabItem { Label("Key Mapping", systemImage: "keyboard") } }`. General/KeyMapping are stubs ("Coming soon" placeholder) in phase 1.
- Deployment target is macOS 14.0 — gate any macOS-26-only API with `#available` + fallback (the `Settings` scene, `TabView`, pickers are all pre-14).

## What Goes Where
- **Implementation Steps** (checkboxes): the model, store, enumeration, ghostty apply, the Settings UI, wiring, tests, docs — all in this repo.
- **Post-Completion** (no checkboxes): manual visual verification that live font/theme changes render correctly and that per-session zoom survives a theme change; phases 2+ (General, Key Mapping content).

## Implementation Steps

### Task 1: AppSettings model + SettingsStore (agtermCore, host-free)

**Files:**
- Create: `agtermCore/Sources/agtermCore/AppSettings.swift`
- Create: `agtermCore/Sources/agtermCore/SettingsStore.swift`
- Create: `agtermCore/Tests/agtermCoreTests/AppSettingsTests.swift`
- Create: `agtermCore/Tests/agtermCoreTests/SettingsStoreTests.swift`

- [x] add `AppSettings` value type (`Codable, Equatable, Sendable`): optional `fontFamily`, `fontSize`, `theme` (all optional so old files decode — no `version` field; see Technical Details).
- [x] add `AppSettings.ghosttyConfigLines() -> [String]` (pure): one line per set field (`font-family = …`, `font-size = …`, `theme = …`), values written raw (no quotes); unset fields omitted.
- [x] add `SettingsStore(directory:)` with `load()` (missing/corrupt → `AppSettings()`) and `save(_:) throws`, writing `<directory>/settings.json` (mirror `PersistenceStore`).
- [x] write `AppSettingsTests`: JSON round-trip; a file missing a later field still decodes (optional fields); `ghosttyConfigLines()` — set vs unset fields produce/omit lines, and values with spaces (e.g. theme `3024 Night`) pass through raw (no quotes).
- [x] write `SettingsStoreTests`: save→load round-trip; missing file → default; corrupt file → default; creates directory when missing.
- [x] run `cd agtermCore && swift test` — must pass before Task 2. (127 tests green.)

### Task 2: Settings persistence wiring + observable SettingsModel (app)

**Files:**
- Create: `agterm/SettingsModel.swift`
- Modify: `agterm/agtermApp.swift`

- [ ] add `@Observable @MainActor SettingsModel` wrapping `SettingsStore`: loads `AppSettings` at init (honor `AGTERM_STATE_DIR`, same resolution as `restoredStore()`), exposes the current settings, and on mutation saves via the store. (Live ghostty apply is wired in Task 4 — for now, just persist.)
- [ ] create the `SettingsModel` in `agtermApp.init` (like `store`/`actions`) and hold it as `@State`.
- [ ] no new unit test here: `SettingsModel` is a thin `@MainActor @Observable` wrapper over the agtermCore-tested `SettingsStore`; its behavior is exercised end-to-end by the Task 6 XCUITest (settings.json file oracle). State this explicitly rather than implying agtermCore covers the wrapper.
- [ ] run agtermCore tests + build — must pass before Task 3.

### Task 3: Theme + monospaced-font enumeration (app)

**Files:**
- Create: `agterm/SettingsCatalog.swift`
- Create: `agtermUITests/` (none here — covered by Task 6)

- [ ] add `SettingsCatalog` (app target): `themeNames() -> [String]` from the bundle `ghostty/themes` dir (sorted, case-insensitive); `monospacedFontFamilies() -> [String]` via `NSFontManager` filtered to fixed-pitch (sorted).
- [ ] handle the empty/missing cases (no themes dir → empty list → the picker shows only "Default").
- [ ] write a lightweight check (assert non-empty theme list against the real bundle is an XCUITest/integration concern; the pure sort/filter helpers, if any are factored into agtermCore, get unit tests). Keep enumeration in the app target (needs the bundle + AppKit); no host-free unit test required here.
- [ ] build — must pass before Task 4.

### Task 4: Ghostty config application — write settings.conf, load it, broadcast a live re-skin (app)

**Files:**
- Modify: `agterm/Ghostty/GhosttyApp.swift` (write conf, load it in `loadConfig`, build config, ownership)
- Modify: `agterm/Ghostty/GhosttySurfaceView.swift` (add `applyConfig`)
- Modify: `agterm/Views/QuickTerminal.swift` (non-creating surface accessor)
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift` (reset per-session sizes)
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreTests.swift`
- Create: `agterm/ConfigApplier.swift` (coordinator)
- Modify: `agterm/SettingsModel.swift` (trigger apply on change)

- [ ] FIRST (gate the broadcast on this): resolve `update_config` config ownership — read upstream ghostty source or test one apply under Instruments. Decide free-vs-retain for agterm's single long-lived `config` (likely: swap `self.config` to the new one, free the previous after the broadcast).
- [ ] write `ghostty-settings.conf` from `AppSettings.ghosttyConfigLines()` at the settings directory; `GhosttyApp.loadConfig` loads it after the user config, before `finalize` (UI wins on launch).
- [ ] add `GhosttySurfaceView.applyConfig(_ cfg: ghostty_config_t)` → `ghostty_surface_update_config`; the coordinator reaches surfaces by downcasting `any TerminalSurface` → `GhosttySurfaceView`.
- [ ] add `QuickTerminalController.currentSurface() -> GhosttySurfaceView?` — returns the existing surface WITHOUT creating one (so the broadcast never spawns a shell).
- [ ] add `AppStore.resetSessionFontSizes()` (agtermCore): set every `Session.fontSize = nil` and `save()`; unit-test it.
- [ ] add `ConfigApplier` (app, `@MainActor`): on apply — rebuild the config, `ghostty_app_update_config(app, cfg)`, `applyConfig` on every live surface (each session's `surface` + `splitSurface` via the store, plus the quick terminal's current surface), then `store.resetSessionFontSizes()` (keeps state consistent with the shared default).
- [ ] wire `SettingsModel` mutations to call `ConfigApplier`.
- [ ] write tests: `AppStore.resetSessionFontSizes()` (agtermCore unit test); `ghosttyConfigLines()` already tested in Task 1; the live broadcast + zoom reset are verified manually + via the Task 6 XCUITest (settings.json oracle).
- [ ] run tests + build — must pass before Task 5.

### Task 5: Settings window UI — three tabs, Appearance populated (app)

**Files:**
- Create: `agterm/Views/SettingsView.swift`
- Modify: `agterm/agtermApp.swift` (add the `Settings { }` scene)

- [ ] add a `Settings { SettingsView(settings: settingsModel, catalog: …) }` scene to `agtermApp`.
- [ ] `SettingsView`: a `TabView` with General (stub placeholder), Appearance, Key Mapping (stub placeholder).
- [ ] Appearance tab: a font-family `Picker` (monospaced families + "Default"), a font-size control (stepper/field with a sane range), a theme `Picker` (theme names + "Default"); all bound to `SettingsModel` so a change persists and live-applies.
- [ ] add accessibility identifiers on the Appearance controls (e.g. `settings-theme`, `settings-font-size`, `settings-font-family`) for XCUITest.
- [ ] build + manual check: changing a control updates the running terminal live.
- [ ] (tests in Task 6) — must pass before Task 6.

### Task 6: XCUITest + docs

**Files:**
- Create: `agtermUITests/SettingsUITests.swift`
- Modify: `README.md`, `CLAUDE.md`

- [ ] `SettingsUITests`: launch with `AGTERM_STATE_DIR`, open Settings with the **Cmd+, keystroke** (`app.typeKey(",", modifierFlags: .command)` — what the `Settings` scene binds; the `agterm ▸ Settings…` menu item is documentation only, not the test driver), select the Appearance tab, change the theme (and font size), and assert the chosen value lands in `<stateDir>/settings.json` (file oracle).
- [ ] verify the Settings window has all three tabs (General/Appearance/Key Mapping reachable).
- [ ] document the feature: README (Settings window + Appearance controls), CLAUDE.md (AppSettings/SettingsStore + the ghostty-settings.conf apply path + per-session-zoom preservation note).
- [ ] run the full gate (`cd agtermCore && swift test` + all `agtermUITests`).

### Task 7: Verify acceptance criteria
- [ ] Settings window opens (Cmd+,) with General / Appearance / Key Mapping tabs.
- [ ] Appearance: font family, default font size, and theme are selectable, persist to `settings.json`, survive relaunch, and apply live to running terminals.
- [ ] Applying an appearance change resets all open terminals to the new default size and clears per-session cmd-+/- zoom (the user-approved simplification) — state stays consistent across relaunch.
- [ ] Full test suite green; clean build, no warnings.

### Task 8: [Final] Finish docs + move plan
- [ ] confirm README.md / CLAUDE.md updated.
- [ ] move this plan to `docs/plans/completed/`.

## Post-Completion
*Items requiring manual intervention or external systems — informational only.*

**Manual verification:**
- Visually confirm live font-family / font-size / theme changes render correctly on existing terminals (split + quick terminal too), and that applying a change resets per-session cmd-+/- zoom to the new default (the approved behavior).
- Confirm the bundled themes list is complete and selecting a few representative themes (light/dark) looks right.

**Future phases (out of scope for phase 1):**
- General tab content; Key Mapping tab content (rebindable shortcuts) — these arrive in later phases per the user's "we will continue with other parts".

---
Smells pre-check: skipped — non-Go project.
