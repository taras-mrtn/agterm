import agtCore
import AppKit

/// The user-facing actions shared by the toolbar / bottom-bar buttons (`ContentView`) and the
/// menu bar (`agtApp`'s `.commands`), so the two never drift. `@MainActor`; holds the store, and
/// resolves the focused terminal for font commands.
///
/// Trivial one-liners (quick-terminal toggle, status-bar toggle) are not here — their callers
/// invoke the controller/store directly. This type owns the actions that carry real logic:
/// new-session placement, the directory picker, and the split/focus/font handling.
@MainActor
final class AppActions {
    private let store: AppStore

    /// Set briefly while a rename is being started, so the focus-restore that runs when a palette
    /// or the quick terminal closes doesn't steal first responder from the inline rename field.
    private var renamePending = false

    init(store: AppStore) {
        self.store = store
    }

    // MARK: - Workspaces & sessions

    func newWorkspace() {
        store.addWorkspace(name: store.defaultWorkspaceName)
    }

    func newSession() {
        guard let workspaceID = store.currentWorkspaceID,
              let session = store.addSession(toWorkspace: workspaceID,
                                             cwd: FileManager.default.homeDirectoryForCurrentUser.path)
        else { return }
        store.selectSession(session.id)
    }

    func openDirectory() {
        guard let workspaceID = store.currentWorkspaceID else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a directory for the new session"
        guard panel.runModal() == .OK, let url = panel.url,
              let session = store.addSession(toWorkspace: workspaceID, cwd: url.path)
        else { return }
        store.selectSession(session.id)
    }

    func closeActiveSession() {
        guard let id = store.selectedSessionID else { return }
        store.closeSession(id)
    }

    func toggleStatusBar() {
        store.setStatusBarHidden(!store.statusBarHidden)
    }

    /// Move a session to another workspace (used by the palette's "Move Session to …" items).
    func moveSession(_ sessionID: UUID, toWorkspace workspaceID: UUID) {
        store.moveSession(sessionID, toWorkspace: workspaceID)
    }

    // MARK: - Inline rename

    /// Start an inline rename of the active session. The sidebar owns the edit field, so this posts
    /// a notification it observes; `renamePending` keeps the palette-close focus restore off the
    /// field while the edit starts.
    func renameActiveSession() {
        guard store.activeSession != nil else { return }
        renamePending = true
        NotificationCenter.default.post(name: .agtBeginRenameSession, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.renamePending = false }
    }

    /// Start an inline rename of the active session's workspace (the same one new sessions land in).
    func renameActiveWorkspace() {
        guard store.currentWorkspaceID != nil else { return }
        renamePending = true
        NotificationCenter.default.post(name: .agtBeginRenameWorkspace, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.renamePending = false }
    }

    // MARK: - Command palettes

    /// The app's commands as palette items, sharing the same logic as the menu/buttons. Includes a
    /// "Move Session to …" item per other workspace (when there's an active session to move).
    func paletteActions() -> [PaletteItem] {
        var items: [PaletteItem] = [
            PaletteItem(title: "New Session") { [weak self] in self?.newSession() },
            PaletteItem(title: "New Workspace") { [weak self] in self?.newWorkspace() },
            PaletteItem(title: "Open Directory…") { [weak self] in self?.openDirectory() },
            PaletteItem(title: "Rename Session") { [weak self] in self?.renameActiveSession() },
            PaletteItem(title: "Rename Workspace") { [weak self] in self?.renameActiveWorkspace() },
            PaletteItem(title: "Close Session") { [weak self] in self?.closeActiveSession() },
            PaletteItem(title: "Toggle Split") { [weak self] in self?.toggleSplit() },
            PaletteItem(title: "Quick Terminal") { QuickTerminalController.shared.toggle() },
            PaletteItem(title: "Increase Font Size") { [weak self] in self?.increaseFontSize() },
            PaletteItem(title: "Decrease Font Size") { [weak self] in self?.decreaseFontSize() },
            PaletteItem(title: "Actual Font Size") { [weak self] in self?.resetFontSize() },
            PaletteItem(title: "Toggle Status Bar") { [weak self] in self?.toggleStatusBar() },
        ]
        if let current = store.currentWorkspaceID, let sessionID = store.selectedSessionID {
            for workspace in store.workspaces where workspace.id != current {
                let target = workspace.id
                items.append(PaletteItem(id: "move-\(target)", title: "Move Session to \(workspace.name)") { [weak self] in
                    self?.moveSession(sessionID, toWorkspace: target)
                })
            }
        }
        return items
    }

    /// Every open session across workspaces as palette items; choosing one selects it.
    func paletteSessions() -> [PaletteItem] {
        let store = self.store
        return store.workspaces.flatMap { workspace in
            workspace.sessions.map { session in
                let id = session.id
                return PaletteItem(id: id.uuidString, title: session.displayName, subtitle: session.effectiveCwd) {
                    store.selectSession(id)
                }
            }
        }
    }

    // MARK: - Split

    func toggleSplit() {
        guard let session = store.activeSession else { return }
        store.toggleSplit(session.id)
        focusSplitPane(session, wantSplit: session.isSplit)
    }

    // MARK: - Font (on the focused terminal)

    func increaseFontSize() { focusedSurface()?.performBindingAction("increase_font_size:1") }
    func decreaseFontSize() { focusedSurface()?.performBindingAction("decrease_font_size:1") }
    func resetFontSize() { focusedSurface()?.performBindingAction("reset_font_size") }

    // MARK: - Focus

    /// Move first responder back to the active session's primary terminal (used after the quick
    /// terminal or a palette closes). Re-asserts briefly since the target view may not be on-window
    /// yet. Bails while the quick terminal is up — it owns focus, so don't steal it back.
    func focusActiveSession(attempt: Int = 0) {
        if renamePending { return }
        if QuickTerminalController.shared.isVisible { return }
        if let view = store.activeSession?.surface as? GhosttySurfaceView, let window = view.window {
            window.makeFirstResponder(view)
        }
        guard attempt < 12 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.focusActiveSession(attempt: attempt + 1)
        }
    }

    /// Move first responder to the split (right) pane on open, or the primary on close.
    /// Re-asserts over a short window because the split surface materializes a beat after the
    /// toggle and the HSplitView collapse churns the primary view.
    func focusSplitPane(_ session: Session, wantSplit: Bool, attempt: Int = 0) {
        if let view = (wantSplit ? session.splitSurface : session.surface) as? GhosttySurfaceView,
           let window = view.window {
            window.makeFirstResponder(view)
        }
        guard attempt < 12 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.focusSplitPane(session, wantSplit: wantSplit, attempt: attempt + 1)
        }
    }

    /// The focused terminal: the key window's first responder if it's a surface (covers the main
    /// pane, the split pane, and the quick terminal), else the active session's primary surface.
    private func focusedSurface() -> GhosttySurfaceView? {
        if let view = NSApp.keyWindow?.firstResponder as? GhosttySurfaceView { return view }
        return store.activeSession?.surface as? GhosttySurfaceView
    }
}
