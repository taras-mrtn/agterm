import agtCore
import SwiftUI

/// Top-level layout: the workspace/session sidebar on the left, the active
/// session's terminal surface on the right. The detail pane swaps surfaces via
/// `.id(session.id)` — each session gets its own `TerminalView` identity, so the
/// session-owned surfaces survive switching.
struct ContentView: View {
    @Bindable var store: AppStore
    let makeSurface: (Session) -> GhosttySurfaceView

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            if let active = store.activeSession {
                TerminalView(session: active, makeSurface: makeSurface)
                    .id(active.id)
            } else {
                Text("No session selected")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
