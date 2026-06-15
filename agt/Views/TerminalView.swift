import agtCore
import GhosttyKit
import SwiftUI

/// Bridges one session's libghostty surface (a `GhosttySurfaceView`) into SwiftUI.
///
/// The surface is owned by the `Session` (`session.surface`), not the
/// representable. `makeNSView` returns the session's cached surface view,
/// creating it through the app-supplied `makeSurface` factory on first display;
/// `dismantleNSView` is a no-op so the surface (and its shell) survives view
/// churn when switching sessions. Only an explicit `teardown()` frees it.
///
/// Each `TerminalView(session).id(session.id)` gets its own representable
/// identity, so switching sessions dismantles the old view and makes a new one,
/// but the session-owned surfaces stay alive.
struct TerminalView: NSViewRepresentable {
    let session: Session
    /// Lazily creates a `GhosttySurfaceView` for the session and stores it on
    /// `session.surface`. Supplied by the app target.
    let makeSurface: (Session) -> GhosttySurfaceView

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context _: Context) -> GhosttySurfaceView {
        if let existing = session.surface as? GhosttySurfaceView {
            return existing
        }
        let view = makeSurface(session)
        session.surface = view
        return view
    }

    func updateNSView(_ nsView: GhosttySurfaceView, context: Context) {
        // Deferred surface creation: makeNSView may have run before the view had
        // a sized window. createSurface is idempotent (guards surface == nil and
        // backing size), so calling it here is safe.
        nsView.createSurface()
        focusIfNeeded(nsView, coordinator: context.coordinator)
    }

    /// Grabs first responder for this session's surface only when it is the
    /// natural focus target, so unrelated detail-pane re-renders (window resize,
    /// observable invalidations) don't steal focus.
    ///
    /// Focus is taken once, when this representable first attaches to a window
    /// (each `TerminalView(session).id(session.id)` is a fresh representable, so
    /// this fires when a session becomes active). On later updates focus is left
    /// alone unless the surface already holds it — and never grabbed while a text
    /// field editor is first responder, so editing a sidebar rename survives a
    /// re-render. Mouse clicks (`mouseDown`) cover focus for the rest.
    private func focusIfNeeded(_ nsView: GhosttySurfaceView, coordinator: Coordinator) {
        guard let window = nsView.window else { return }
        if window.firstResponder === nsView { return }
        // don't steal focus from an active text field editor (e.g. a sidebar
        // rename TextField); its field editor is an NSText serving the window.
        if window.firstResponder is NSText { return }
        guard !coordinator.didFocus else { return }
        coordinator.didFocus = true
        window.makeFirstResponder(nsView)
    }

    static func dismantleNSView(_: GhosttySurfaceView, coordinator _: Coordinator) {
        // No-op: the surface outlives the representable and is owned by the
        // session. Only an explicit teardown() may free it.
    }

    /// Tracks whether this representable has already claimed first responder, so
    /// focus is grabbed only on first attach, not on every `updateNSView`.
    final class Coordinator {
        var didFocus = false
    }
}
