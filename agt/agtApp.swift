import agtCore
import AppKit
import SwiftUI

@main
struct agtApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    private var appDelegate

    @State private var store: AppStore
    @State private var gitStatusService: GitStatusService
    @State private var actions: AppActions
    @State private var palette = PaletteController()

    init() {
        let store = agtApp.restoredStore()
        _store = State(initialValue: store)
        _gitStatusService = State(initialValue: GitStatusService(store: store))
        _actions = State(initialValue: AppActions(store: store))
    }

    var body: some Scene {
        Window("agt", id: "main") {
            ContentView(
                store: store,
                makeSurface: { Self.makeSurface(for: $0, store: store, service: gitStatusService) },
                makeSplitSurface: { Self.makeSplitSurface(for: $0, store: store) },
                quickTerminal: QuickTerminalController.shared,
                actions: actions,
                palette: palette
            )
                .frame(minWidth: 640, minHeight: 400)
                .task {
                    appDelegate.store = store
                    // the quick terminal spawns its shell in the active session's directory
                    // (home when nothing is selected).
                    QuickTerminalController.shared.cwdProvider = {
                        store.activeSession?.effectiveCwd ?? FileManager.default.homeDirectoryForCurrentUser.path
                    }
                    // start the active-session refresh loop + focus observers once
                    // the scene appears (idempotent if the task re-runs).
                    gitStatusService.start()
                }
                // refresh git status for the active session whenever the selection
                // changes, so the result is observable as soon as a session is shown.
                .onChange(of: store.selectedSessionID, initial: true) {
                    gitStatusService.refreshActive()
                }
        }
        .defaultSize(width: 900, height: 600)
        .windowResizability(.contentMinSize)
        .commands {
            // File: replace the default "New" with session/workspace/directory creation, and
            // add Close Session (terminal-style ⌘W — closes the active session, or the window
            // when none is open).
            CommandGroup(replacing: .newItem) {
                Button("New Session") { actions.newSession() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("New Workspace") { actions.newWorkspace() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Open Directory…") { actions.openDirectory() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("Rename Session") { actions.renameActiveSession() }
                    .disabled(store.activeSession == nil)
                Button("Rename Workspace") { actions.renameActiveWorkspace() }
                    .disabled(store.currentWorkspaceID == nil)
                Button("Close Session") {
                    if store.activeSession != nil { actions.closeActiveSession() }
                    else { NSApp.keyWindow?.performClose(nil) }
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            // View: split + quick terminal, near the sidebar toggle.
            CommandGroup(after: .sidebar) {
                Button(store.activeSession?.isSplit == true ? "Hide Split" : "Split Right") {
                    actions.toggleSplit()
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(store.activeSession == nil)
                Button("Quick Terminal") { QuickTerminalController.shared.toggle() }
                    .keyboardShortcut("`", modifiers: .control)
                Button("Go to Session") { palette.toggle(.sessions) }
                    .keyboardShortcut("p", modifiers: .control)
                Button("Command Palette") { palette.toggle(.actions) }
                    .keyboardShortcut("p", modifiers: [.control, .shift])
            }
            // View: font zoom (drives ghostty on the focused terminal) + the status-bar toggle.
            CommandGroup(after: .toolbar) {
                Button("Increase Font Size") { actions.increaseFontSize() }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Decrease Font Size") { actions.decreaseFontSize() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { actions.resetFontSize() }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
                Button(store.statusBarHidden ? "Show Status Bar" : "Hide Status Bar") {
                    store.setStatusBarHidden(!store.statusBarHidden)
                }
                .keyboardShortcut("/", modifiers: .command)
            }
        }
    }

    /// Loads the persisted snapshot and restores it; if there's nothing saved,
    /// seeds a single default workspace with one session at $HOME.
    @MainActor
    private static func restoredStore() -> AppStore {
        // UI tests pass AGT_STATE_DIR to isolate persistence in a temp dir so a
        // run never touches the user's real workspaces.json.
        let persistence = ProcessInfo.processInfo.environment["AGT_STATE_DIR"]
            .map { PersistenceStore(directory: URL(fileURLWithPath: $0, isDirectory: true)) }
            ?? PersistenceStore()
        let store = AppStore(persistence: persistence)
        let snapshot = persistence.load()
        guard !snapshot.workspaces.isEmpty else {
            let workspace = store.addWorkspace(name: "workspace 1")
            store.addSession(toWorkspace: workspace.id, cwd: FileManager.default.homeDirectoryForCurrentUser.path)
            return store
        }
        store.restore(from: snapshot)
        return store
    }

    /// Surface factory: creates a libghostty-backed view for the session, spawning
    /// a login shell in the session's initial working directory. On shell exit the
    /// view calls back to close the owning session in the store.
    @MainActor
    private static func makeSurface(for session: Session, store: AppStore, service: GitStatusService) -> GhosttySurfaceView {
        let view = GhosttySurfaceView(workingDirectory: session.initialCwd, fontSize: session.fontSize.map(Float.init))
        view.session = session
        let sessionID = session.id
        view.onExit = { store.closeSession(sessionID) }
        view.onCwdChange = { service.requestRefresh(sessionID: sessionID) }
        view.onFocusChange = { focused in if focused { store.session(withID: sessionID)?.splitFocused = false } }
        view.onFontSizeChange = { store.setFontSize(sessionID, $0) }
        return view
    }

    /// Split-pane surface factory: a second independent login shell in the session's
    /// current directory. Deliberately NOT wired to the session (no `view.session`) so its
    /// PWD reports don't clobber the session's cwd/git, and on shell exit it closes just
    /// the split (hide + teardown), not the whole session.
    @MainActor
    private static func makeSplitSurface(for session: Session, store: AppStore) -> GhosttySurfaceView {
        // seed the split from the session's font size so it matches the primary; its own
        // cmd +/- changes aren't persisted (the split re-spawns fresh on restore).
        let view = GhosttySurfaceView(workingDirectory: session.effectiveCwd, fontSize: session.fontSize.map(Float.init))
        let sessionID = session.id
        view.onExit = { store.closeSplit(sessionID) }
        view.onFocusChange = { focused in if focused { store.session(withID: sessionID)?.splitFocused = true } }
        return view
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The shared app state, handed over once the scene appears so the delegate can
    /// persist it on terminate.
    var store: AppStore?

    func applicationWillFinishLaunching(_: Notification) {
        // a Debug app launched from DerivedData (ad-hoc signed) never hands the Dock a
        // non-default tile icon via the usual runtime path. set it explicitly. load the
        // artwork straight from the compiled asset catalog rather than via
        // NSWorkspace.icon(forFile:), whose Icon Services cache is keyed by bundle path
        // and the DerivedData path is reused across rebuilds, so it serves a stale tile.
        if let icon = NSImage(named: "AppIcon") {
            NSApp.applicationIconImage = icon
        }
    }

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        // Boot libghostty: init, config, app_new, 120fps tick.
        _ = GhosttyApp.shared
    }

    func applicationWillTerminate(_: Notification) {
        store?.save()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }
}
