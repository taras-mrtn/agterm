import agtCore
import SwiftUI

/// Two-level sidebar: a `DisclosureGroup` per workspace, with selectable session
/// rows underneath. Workspace headers are non-selectable; only sessions are
/// `List(selection:)` targets, so a single `selectedSessionID` backs the list.
///
/// Both workspace and session rows rename inline through one unified
/// `RenamableRow`: a `Text`↔`TextField` toggle keyed by a single `@FocusState`,
/// entered via double-click or the context menu, committed on submit / focus
/// loss, canceled on Escape.
struct SidebarView: View {
    @Bindable var store: AppStore

    /// The row currently being renamed (session or workspace id), or nil.
    @FocusState private var editingID: UUID?

    /// Workspace ids whose disclosure group is collapsed. Absent = expanded, so
    /// new workspaces start open without seeding this set.
    @State private var collapsed: Set<UUID> = []

    var body: some View {
        List(selection: selection) {
            ForEach(store.workspaces) { workspace in
                DisclosureGroup(isExpanded: expansion(for: workspace.id)) {
                    ForEach(workspace.sessions) { session in
                        RenamableRow(
                            id: session.id,
                            text: session.displayName,
                            editingID: $editingID,
                            commit: { store.renameSession(session.id, to: $0) }
                        ) {
                            moveMenu(for: session, from: workspace)
                            Button("Close Session", role: .destructive) {
                                store.closeSession(session.id)
                            }
                        }
                        .tag(session.id)
                        .draggable(session.id.uuidString)
                    }
                } label: {
                    RenamableRow(
                        id: workspace.id,
                        text: workspace.name,
                        font: .headline,
                        editingID: $editingID,
                        commit: { store.renameWorkspace(workspace.id, to: $0) }
                    ) {
                        Button("New Session") {
                            store.addSession(toWorkspace: workspace.id, cwd: defaultCwd)
                        }
                    }
                    .dropDestination(for: String.self) { items, _ in
                        drop(items, into: workspace.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button {
                    store.addWorkspace(name: defaultWorkspaceName)
                } label: {
                    Label("New Workspace", systemImage: "plus")
                }
            }
        }
    }

    /// The list-selection binding, routed through `AppStore.selectSession` so a
    /// sidebar click persists the selection immediately. Binding the stored
    /// property directly would set it without saving, leaving selection persisted
    /// only on the next structural mutation or on terminate.
    private var selection: Binding<UUID?> {
        Binding(
            get: { store.selectedSessionID },
            set: { store.selectSession($0) }
        )
    }

    /// A two-way binding for a workspace's expansion state, backed by the
    /// `collapsed` set (absent = expanded).
    private func expansion(for workspaceID: UUID) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(workspaceID) },
            set: { isExpanded in
                if isExpanded { collapsed.remove(workspaceID) } else { collapsed.insert(workspaceID) }
            }
        )
    }

    private var defaultCwd: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    private var defaultWorkspaceName: String {
        "workspace \(store.workspaces.count + 1)"
    }

    /// Handles a drop of dragged session-id strings onto a workspace header,
    /// appending each resolved session into the target workspace via
    /// `AppStore.moveSession` (append — `at: nil`). A drop onto the session's
    /// current workspace is rejected (no-op), so it doesn't pointlessly reorder
    /// the session to the bottom. The context-menu `Move to` stays the guaranteed
    /// path; cross-section drag in a `List` is unreliable. Returns true if at
    /// least one item moved to a different workspace.
    private func drop(_ items: [String], into workspaceID: UUID) -> Bool {
        var moved = false
        for item in items {
            guard let id = UUID(uuidString: item), let owner = store.workspace(forSession: id), owner.id != workspaceID else { continue }
            store.moveSession(id, toWorkspace: workspaceID)
            moved = true
        }
        return moved
    }

    /// A `Move to ▸ <workspace>` submenu listing every workspace other than the
    /// session's current one, each moving the session via `AppStore.moveSession`.
    @ViewBuilder
    private func moveMenu(for session: Session, from workspace: Workspace) -> some View {
        let targets = store.workspaces.filter { $0.id != workspace.id }
        if !targets.isEmpty {
            Menu("Move to") {
                ForEach(targets) { target in
                    Button(target.name) {
                        store.moveSession(session.id, toWorkspace: target.id)
                    }
                }
            }
        }
    }
}

/// A single sidebar row that toggles between a `Text` label and an editing
/// `TextField` (constant view count). Edit mode is driven by `editingID`: when it
/// equals this row's `id`, the field is shown and focused. Entered via
/// double-click or the "Rename" context-menu item; committed on submit and on
/// focus loss; canceled on Escape (which resets the draft and clears focus).
private struct RenamableRow<MenuContent: View>: View {
    let id: UUID
    let text: String
    var font: Font?
    @FocusState.Binding var editingID: UUID?
    let commit: (String) -> Void
    @ViewBuilder let extraMenu: () -> MenuContent

    @State private var draft = ""
    /// When Enter or Escape ends the edit, it clears `editingID`, which also
    /// fires the focus-loss `onChange`. Both paths set this flag first so that
    /// `onChange` skips its own commit: Enter has already committed, Escape wants
    /// to discard. Only a genuine focus loss (click elsewhere) leaves it false,
    /// so `onChange` is the one path that commits on focus loss.
    @State private var suppressOnChangeCommit = false

    var body: some View {
        Group {
            if editingID == id {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($editingID, equals: id)
                    .onSubmit { commitDraft() }
                    .onExitCommand { cancel() }
                    .onChange(of: editingID) { _, new in
                        // focus moved away from this row: commit the captured
                        // draft. editingID has already changed, so we must NOT
                        // re-check it == id here, or the edit would be dropped.
                        guard new != id else { return }
                        if suppressOnChangeCommit {
                            suppressOnChangeCommit = false
                        } else {
                            commit(draft)
                        }
                    }
            } else {
                Text(text)
                    .font(font)
            }
        }
        .contextMenu {
            Button("Rename") { beginEditing() }
            extraMenu()
        }
        .onTapGesture(count: 2) { beginEditing() }
    }

    private func beginEditing() {
        draft = text
        suppressOnChangeCommit = false
        editingID = id
    }

    /// Enter/submit: commit the draft and exit edit mode. Clearing `editingID`
    /// fires the focus-loss `onChange`, so we suppress that path first to keep it
    /// from committing a second time.
    private func commitDraft() {
        commit(draft)
        suppressOnChangeCommit = true
        editingID = nil
    }

    /// Escape: discard the draft and exit edit mode. Suppress the focus-loss
    /// `onChange` so the discarded draft isn't committed.
    private func cancel() {
        suppressOnChangeCommit = true
        editingID = nil
    }
}
