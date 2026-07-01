# Changelog

## v0.5.1 - 2026-07-01

### Bug Fixes

- hide the sidebar scroll bar when the tree fits, instead of always showing a track under macOS "Show scroll bars: Always" ab1d4a8 @umputun

## v0.5.0 - 2026-07-01

### New Features

- per-session background watermark, set via session.background #32 @fkirill
- read a session's scrollback over the control API with session.text #46 @paul-nameless
- show the app-wide unseen-notification count as a Dock icon badge #48 @vnazarenko

### Improvements

- show the configured keyboard shortcut in toolbar and sidebar tooltips #62 @taras-mrtn

## v0.4.2 - 2026-07-01

### Bug Fixes

- right-click paste works out of the box, with a General settings toggle to disable it #63 @umputun
- file drops land on the visible session instead of an invisible background one #63 @umputun

## v0.4.1 - 2026-07-01

### Improvements

- double-click the window header to zoom, honoring the macOS title-bar double-click setting #33 @fkirill
- session.resize control command to move the split divider #59 @umputun
- reorganize Settings into five focused tabs #60 @umputun

### Bug Fixes

- restore sessions started with a command (e.g. ssh) on relaunch, instead of coming back as plain shells #61 @umputun

## v0.4.0 - 2026-06-30

### New Features

- session attention list and title-bar indicator #35 @umputun
- insert dropped file paths as text on drag-and-drop #52 @umputun
- optional one-shot sound on session.status #38 @umputun
- make the agterm agent skill user-invocable 58ff68f @umputun
- fish shell integration for agent-status hooks #56 @korjavin

### Improvements

- de-bounce repeated identical status sounds #40 @umputun
- enrich the About panel with repo link, copyright, and build commit 800add3 @umputun

### Bug Fixes

- forward right- and middle-click to libghostty #53 @umputun
- Esc cancels inline rename and focus returns to the terminal #42 @umputun

## v0.3.1 - 2026-06-29

### Improvements

- make global ghostty config inheritance opt-in (default off) #29 @umputun

### Bug Fixes

- ⌘C/⌘V copy/paste on non-Latin keyboard layouts #31 @umputun
- active status color default and "default ghostty" theme picker label bac948c
- clear the active agent-status glyph on Esc-interrupt #28 @umputun
