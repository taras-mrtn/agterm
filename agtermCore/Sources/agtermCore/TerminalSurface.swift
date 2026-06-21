import Foundation

/// The app-side terminal surface (a libghostty-backed NSView) seen by the
/// host-free model. Kept minimal so `agtermCore` stays free of GhosttyKit/AppKit:
/// the concrete `GhosttySurfaceView` in the app target conforms to it.
///
/// `@MainActor`-isolated: the only owner is the `@MainActor` `Session`, and the
/// concrete conformer is a `@MainActor` `NSView`, so isolation lines up without
/// crossing actor boundaries.
@MainActor
public protocol TerminalSurface: AnyObject {
    /// Frees the underlying libghostty surface and shell. Called when the
    /// owning session is closed.
    func teardown()
}
