import Foundation
import Observation

/// One shell, backed by a single libghostty surface.
///
/// `@MainActor` (so it's implicitly `Sendable` via isolation — never made an
/// `actor`). The `surface` slot is `@ObservationIgnored` so assigning the
/// lazily-created NSView never churns observation; `customName`/`currentCwd` are
/// observed, so the sidebar refreshes when a rename or PWD report lands.
@Observable
@MainActor
public final class Session: Identifiable {
    public let id: UUID
    public var customName: String?
    /// The live working directory from the latest OSC 7 / PWD report. Observed, so
    /// the sidebar row refreshes when it changes. It is captured by `snapshot()`
    /// and so persisted on quit and on structural mutations, but a bare `cd` does
    /// not trigger a save (OSC 7 fires constantly), so a crash loses only cwd
    /// changes since the last structural mutation.
    public var currentCwd: String?
    public let initialCwd: String

    /// The terminal title from the latest OSC 0/1/2 set-title report — set by a shell
    /// `PROMPT_COMMAND`, ghostty's shell integration, or a remote host over SSH. Observed, so the
    /// sidebar row refreshes when it changes. Ephemeral like `currentCwd`/`unseenCount`:
    /// `SessionSnapshot` doesn't capture it, and a bare prompt redraw doesn't trigger a save.
    public var oscTitle: String?

    /// Count of unseen terminal notifications fired by this session's panes while it wasn't focused.
    /// Observed, so the sidebar badge reacts. Ephemeral: `SessionSnapshot` doesn't capture it, so it
    /// never survives a relaunch.
    public var unseenCount: Int = 0

    /// The app-side surface (a `GhosttySurfaceView`). Lazily created on first
    /// display and owned here so it survives sidebar/detail view churn.
    @ObservationIgnored public var surface: (any TerminalSurface)?

    /// Whether the session is shown as a one-level vertical split (two panes side by
    /// side). Observed, so the detail pane shows/hides the second pane when toggled.
    public var isSplit: Bool = false

    /// While split, whether the split (second) pane holds focus rather than the primary.
    /// Observed, so the detail pane can dim the inactive pane. Meaningless when not split.
    public var splitFocused: Bool = false

    /// The second pane's surface, lazily created on first split. `@ObservationIgnored`
    /// like `surface`; it survives view churn, so hiding the split keeps the shell alive
    /// rather than destroying it. Freed only on `closeSplit`/`closeSession`.
    @ObservationIgnored public var splitSurface: (any TerminalSurface)?

    /// The terminal font size in points, or nil to use the ghostty config default. The app
    /// sets the surface's initial size from this on creation and writes it back when the
    /// user changes it (cmd +/-). `@ObservationIgnored`: nothing in SwiftUI reacts to it —
    /// it is read imperatively at surface creation and captured by `snapshot()`.
    @ObservationIgnored public var fontSize: Double?

    /// Whether an ephemeral overlay terminal is shown on top of this session (full single-pane
    /// size, hiding the single/split content underneath). Observed, so the detail pane shows/hides
    /// the overlay. Driven only by the control channel; NOT persisted (absent from `snapshot()`), so
    /// the overlay never survives a relaunch — it exists only to run one program and vanish.
    public var overlayActive: Bool = false

    /// The overlay's surface, created when the overlay opens and torn down when its program exits or
    /// the control channel closes it (unlike the split, which is kept alive when hidden). The shell
    /// runs `overlayCommand`; on its exit the surface's process-exit closes the overlay.
    @ObservationIgnored public var overlaySurface: (any TerminalSurface)?

    /// The command the overlay runs as its process (e.g. `revdiff`); read by the overlay surface
    /// factory at creation. `@ObservationIgnored`: read imperatively, not reactive.
    @ObservationIgnored public var overlayCommand: String?

    /// The overlay's working directory, or nil to inherit `effectiveCwd`. Read by the factory at
    /// creation. `@ObservationIgnored`.
    @ObservationIgnored public var overlayCwd: String?

    /// Whether the overlay keeps its surface open after the command exits, showing libghostty's
    /// "press any key to close" prompt (useful to read a command's final output) instead of closing
    /// immediately. Read by the factory at creation. `@ObservationIgnored`.
    @ObservationIgnored public var overlayWait: Bool = false

    public init(id: UUID = UUID(), initialCwd: String, customName: String? = nil) {
        self.id = id
        self.initialCwd = initialCwd
        self.customName = customName
    }

    /// The sidebar label: a non-blank `customName` (a manual rename) wins; otherwise a non-blank
    /// `oscTitle` (the terminal title the shell or a remote host set); otherwise the basename of the
    /// live cwd (falling back to `initialCwd`).
    ///
    /// `customName` and `oscTitle` are both trimmed before use, so a whitespace-only value falls
    /// through to the next source — matching `AppStore.renameSession`, which clears a blank name to
    /// nil. (A whitespace-only `customName` can only reach here via a hand-edited snapshot;
    /// `renameSession` never stores one.)
    ///
    /// Basename pins: root `/` → `/` (`lastPathComponent` already returns this);
    /// a trailing slash is ignored (`/a/b/` → `b`); an empty path → `~` (no
    /// sensible component exists, so we show the home shorthand).
    public var displayName: String {
        if let trimmed = customName?.trimmedOrNil { return trimmed }
        if let title = oscTitle?.trimmedOrNil { return title }
        let path = currentCwd ?? initialCwd
        if path.isEmpty { return "~" }
        return (path as NSString).lastPathComponent
    }

    /// The session's effective working directory: the live `currentCwd` once a PWD
    /// report has arrived, otherwise the `initialCwd`. Used for the title subtitle and
    /// as the cwd a new split/overlay/quick-terminal inherits.
    public var effectiveCwd: String { currentCwd ?? initialCwd }
}

extension String {
    /// The string trimmed of leading/trailing whitespace and newlines, or nil if
    /// the result is empty. The single normalizer for the rename/displayName
    /// "blank after trim" rule.
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
