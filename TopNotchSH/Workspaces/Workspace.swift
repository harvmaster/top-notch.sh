import Combine
import Foundation

typealias WorkspaceID = UUID

/// A named, ordered set of terminal tabs. Shells are spawned lazily: a
/// workspace has no processes until it is first shown.
@MainActor
final class Workspace: ObservableObject, Identifiable {
    typealias SessionFactory = @MainActor (_ directory: String?) -> TerminalSession

    let id: WorkspaceID
    @Published fileprivate(set) var name: String
    @Published fileprivate(set) var hotkey: KeyChord?
    @Published private(set) var tabs: [TerminalSession] = []
    @Published private(set) var activeTabID: TerminalSession.ID?

    private let makeSession: SessionFactory

    init(id: WorkspaceID = UUID(), name: String, hotkey: KeyChord? = nil, makeSession: @escaping SessionFactory) {
        self.id = id
        self.name = name
        self.hotkey = hotkey
        self.makeSession = makeSession
    }

    var activeTab: TerminalSession? {
        tabs.first { $0.id == activeTabID }
    }

    var activeIndex: Int? {
        tabs.firstIndex { $0.id == activeTabID }
    }

    // MARK: - Tabs

    /// Guarantees at least one tab exists.
    func ensureTab() {
        if tabs.isEmpty { newTab() }
    }

    /// Opens a tab in the active tab's working directory.
    func newTab() {
        let session = makeSession(activeTab?.currentDirectory)
        session.onExit = { [weak self, weak session] in
            guard let self, let session else { return }
            self.remove(session.id)
        }
        tabs.append(session)
        activeTabID = session.id
    }

    func closeTab(_ id: TerminalSession.ID) {
        remove(id)?.terminate()
    }

    func closeActiveTab() {
        guard let activeTabID else { return }
        closeTab(activeTabID)
    }

    /// Removes a tab without terminating it, so it can live on elsewhere.
    func detachTab(_ id: TerminalSession.ID) -> TerminalSession? {
        let session = remove(id)
        session?.onExit = nil
        return session
    }

    func selectTab(_ id: TerminalSession.ID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeTabID = tabs[index].id
    }

    func selectTab(offset: Int) {
        guard let index = activeIndex, !tabs.isEmpty else { return }
        let count = tabs.count
        activeTabID = tabs[((index + offset) % count + count) % count].id
    }

    func moveTab(_ id: TerminalSession.ID, to destination: Int) {
        guard let source = tabs.firstIndex(where: { $0.id == id }) else { return }
        let destination = destination.clamped(to: 0...(tabs.count - 1))
        guard source != destination else { return }
        tabs.insert(tabs.remove(at: source), at: destination)
    }

    func terminateAll() {
        tabs.forEach { $0.terminate() }
        tabs = []
        activeTabID = nil
    }

    /// Removes a tab, activating its right-hand neighbour (or left, at the end).
    /// The last tab is always replaced by a fresh shell.
    @discardableResult
    private func remove(_ id: TerminalSession.ID) -> TerminalSession? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let session = tabs.remove(at: index)

        if tabs.isEmpty {
            activeTabID = nil
            newTab()
        } else if activeTabID == id {
            activeTabID = tabs[min(index, tabs.count - 1)].id
        }
        return session
    }
}

// MARK: - Store

/// Owns every workspace and persists their names and hotkeys.
@MainActor
final class WorkspaceStore: ObservableObject {
    private struct Record: Codable {
        var id: WorkspaceID
        var name: String
        var hotkey: KeyChord?
    }

    @Published private(set) var workspaces: [Workspace] = []

    private let persistence: JSONDefaults<[Record]>
    private let makeSession: Workspace.SessionFactory

    init(defaults: UserDefaults = .standard, makeSession: @escaping Workspace.SessionFactory) {
        persistence = JSONDefaults(key: "workspaces", defaults: defaults)
        self.makeSession = makeSession
        workspaces = persistence.load(fallback: []).map {
            Workspace(id: $0.id, name: $0.name, hotkey: $0.hotkey, makeSession: makeSession)
        }
        if workspaces.isEmpty {
            create()
        }
    }

    var primary: Workspace { workspaces[0] }

    func workspace(_ id: WorkspaceID?) -> Workspace? {
        workspaces.first { $0.id == id }
    }

    /// The workspace `offset` positions away from `id`, wrapping around.
    func workspace(_ id: WorkspaceID, offset: Int) -> Workspace {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return primary }
        let count = workspaces.count
        return workspaces[((index + offset) % count + count) % count]
    }

    @discardableResult
    func create(named name: String? = nil) -> Workspace {
        let workspace = Workspace(name: name ?? nextDefaultName(), makeSession: makeSession)
        workspaces.append(workspace)
        persist()
        return workspace
    }

    func rename(_ workspace: Workspace, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != workspace.name else { return }
        workspace.name = trimmed
        persist()
    }

    func setHotkey(_ hotkey: KeyChord?, for workspace: Workspace) {
        guard workspace.hotkey != hotkey else { return }
        workspace.hotkey = hotkey
        persist()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        workspaces.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    var canDelete: Bool { workspaces.count > 1 }

    /// Deletes a workspace and terminates its shells. Returns the workspace
    /// that should replace it on screens that were showing it.
    @discardableResult
    func delete(_ workspace: Workspace) -> Workspace? {
        guard canDelete, let index = workspaces.firstIndex(where: { $0 === workspace }) else { return nil }
        workspaces.remove(at: index)
        workspace.terminateAll()
        persist()
        return workspaces[max(0, index - 1)]
    }

    private func persist() {
        persistence.save(workspaces.map { Record(id: $0.id, name: $0.name, hotkey: $0.hotkey) })
    }

    private func nextDefaultName() -> String {
        let names = Set(workspaces.map(\.name))
        if !names.contains("Main") { return "Main" }
        return (2...).lazy.map { "Workspace \($0)" }.first { !names.contains($0) }!
    }
}
