import Combine
import Foundation

typealias WorkspaceID = UUID

/// What is remembered about a tab: enough to reopen it, not its process.
struct TabRecord: Codable, Equatable {
    var directory: String?
    var name: String?
}

/// A named, ordered set of terminal tabs. Shells are spawned lazily: a
/// workspace has no processes until it is first shown, at which point any
/// remembered tabs are reopened in their folders.
@MainActor
final class Workspace: ObservableObject, Identifiable {
    /// Creates and starts a session in `directory`, typing `command` first.
    typealias SessionFactory = @MainActor (_ directory: String?, _ command: String?) -> TerminalSession

    private static let closedTabLimit = 10

    let id: WorkspaceID
    @Published fileprivate(set) var name: String
    @Published fileprivate(set) var hotkey: KeyChord?
    /// Folder for the first tab (later tabs follow the active tab's folder).
    @Published fileprivate(set) var directory: String?
    /// Typed into every new tab of this workspace, e.g. `ssh server`.
    @Published fileprivate(set) var startupCommand: String?
    @Published private(set) var tabs: [TerminalSession] = []
    @Published private(set) var activeTabID: TerminalSession.ID?
    /// The most important activity across all tabs, for the closed notch.
    @Published private(set) var activity: SessionActivity?

    /// Called whenever something worth saving changes.
    var onChange: (() -> Void)?

    private let makeSession: SessionFactory
    private var pendingTabs: [TabRecord]
    private var pendingActiveIndex: Int?
    private var closedTabs: [TabRecord] = []
    private var tabSubscriptions = Set<AnyCancellable>()

    init(
        id: WorkspaceID = UUID(),
        name: String,
        hotkey: KeyChord? = nil,
        directory: String? = nil,
        startupCommand: String? = nil,
        restoring tabs: [TabRecord] = [],
        activeIndex: Int? = nil,
        makeSession: @escaping SessionFactory
    ) {
        self.id = id
        self.name = name
        self.hotkey = hotkey
        self.directory = directory
        self.startupCommand = startupCommand
        self.pendingTabs = tabs
        self.pendingActiveIndex = activeIndex
        self.makeSession = makeSession
    }

    var activeTab: TerminalSession? {
        tabs.first { $0.id == activeTabID }
    }

    var activeIndex: Int? {
        tabs.firstIndex { $0.id == activeTabID }
    }

    /// Tabs as they should be saved: live ones, or the not-yet-reopened ones.
    var tabRecords: [TabRecord] {
        guard !tabs.isEmpty else { return pendingTabs }
        return tabs.map { TabRecord(directory: $0.currentDirectory, name: $0.customName) }
    }

    var savedActiveIndex: Int? {
        tabs.isEmpty ? pendingActiveIndex : activeIndex
    }

    var canReopenClosedTab: Bool { !closedTabs.isEmpty }

    // MARK: - Tabs

    /// Guarantees at least one tab, reopening remembered tabs the first time.
    func ensureTab() {
        guard tabs.isEmpty else { return }
        let records = pendingTabs
        let activeIndex = pendingActiveIndex
        pendingTabs = []
        pendingActiveIndex = nil

        guard !records.isEmpty else {
            newTab()
            return
        }
        records.forEach(open)
        selectTab(at: activeIndex.map { min($0, tabs.count - 1) } ?? 0)
    }

    /// Opens a tab in the active tab's folder (or the workspace's folder).
    func newTab() {
        open(TabRecord(directory: activeTab?.currentDirectory ?? directory))
    }

    func reopenClosedTab() {
        guard let record = closedTabs.popLast() else { return }
        open(record)
    }

    func closeTab(_ id: TerminalSession.ID) {
        guard let session = remove(id) else { return }
        remember(session)
        session.terminate()
    }

    func closeActiveTab() {
        guard let activeTabID else { return }
        closeTab(activeTabID)
    }

    func closeOtherTabs(than id: TerminalSession.ID) {
        tabs.filter { $0.id != id }.forEach { closeTab($0.id) }
    }

    /// Removes a tab without terminating it, so it can live on elsewhere.
    func detachTab(_ id: TerminalSession.ID) -> TerminalSession? {
        let session = remove(id)
        session?.onExit = nil
        return session
    }

    func renameTab(_ id: TerminalSession.ID, to name: String?) {
        guard let session = tabs.first(where: { $0.id == id }) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        session.customName = trimmed?.isEmpty == false ? trimmed : nil
        onChange?()
    }

    func selectTab(_ id: TerminalSession.ID) {
        guard tabs.contains(where: { $0.id == id }), activeTabID != id else { return }
        activeTabID = id
        onChange?()
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectTab(tabs[index].id)
    }

    func selectTab(offset: Int) {
        guard let index = activeIndex, !tabs.isEmpty else { return }
        let count = tabs.count
        selectTab(at: ((index + offset) % count + count) % count)
    }

    func moveTab(_ id: TerminalSession.ID, to destination: Int) {
        guard let source = tabs.firstIndex(where: { $0.id == id }) else { return }
        let destination = destination.clamped(to: 0...(tabs.count - 1))
        guard source != destination else { return }
        tabs.insert(tabs.remove(at: source), at: destination)
        onChange?()
    }

    func terminateAll() {
        tabs.forEach { $0.terminate() }
        tabs = []
        activeTabID = nil
        pendingTabs = []
        observeTabs()
    }

    // MARK: - Private

    private func open(_ record: TabRecord) {
        let session = makeSession(record.directory, startupCommand)
        session.customName = record.name
        session.onExit = { [weak self, weak session] in
            guard let self, let session else { return }
            self.remove(session.id)
        }
        tabs.append(session)
        activeTabID = session.id
        observeTabs()
        onChange?()
    }

    private func remember(_ session: TerminalSession) {
        closedTabs.append(TabRecord(directory: session.currentDirectory, name: session.customName))
        if closedTabs.count > Self.closedTabLimit {
            closedTabs.removeFirst()
        }
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
        observeTabs()
        onChange?()
        return session
    }

    private func observeTabs() {
        tabSubscriptions.removeAll()
        let tabs = tabs
        Publishers.MergeMany(tabs.map { $0.$activity.map { _ in () } })
            .prepend(())
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.activity = tabs.compactMap(\.activity).max() }
            .store(in: &tabSubscriptions)
    }
}

// MARK: - Store

/// How a workspace is stored in `workspaces.json`.
struct WorkspaceRecord: Codable {
    var id: WorkspaceID
    var name: String
    var hotkey: KeyChord?
    var directory: String?
    var startupCommand: String?
    var tabs: [TabRecord]?
    var activeIndex: Int?
}

/// Owns every workspace and persists their settings and (optionally) tabs.
@MainActor
final class WorkspaceStore: ObservableObject {

    @Published private(set) var workspaces: [Workspace] = []

    private let file: ConfigFile<[WorkspaceRecord]>
    private let makeSession: Workspace.SessionFactory
    private let restoresTabs: () -> Bool

    init(
        file: ConfigFile<[WorkspaceRecord]>,
        restoresTabs: @escaping () -> Bool = { true },
        makeSession: @escaping Workspace.SessionFactory
    ) {
        self.file = file
        self.makeSession = makeSession
        self.restoresTabs = restoresTabs
        let restore = restoresTabs()
        workspaces = file.loadOrBackUp(defaults: []).map {
            Workspace(
                id: $0.id,
                name: $0.name,
                hotkey: $0.hotkey,
                directory: $0.directory,
                startupCommand: $0.startupCommand,
                restoring: restore ? $0.tabs ?? [] : [],
                activeIndex: restore ? $0.activeIndex : nil,
                makeSession: makeSession
            )
        }
        workspaces.forEach(observe)
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
        observe(workspace)
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

    func setDirectory(_ directory: String?, for workspace: Workspace) {
        let directory = directory?.trimmingCharacters(in: .whitespacesAndNewlines)
        workspace.directory = directory?.isEmpty == false ? directory : nil
        persist()
    }

    func setStartupCommand(_ command: String?, for workspace: Workspace) {
        let command = command?.trimmingCharacters(in: .whitespacesAndNewlines)
        workspace.startupCommand = command?.isEmpty == false ? command : nil
        persist()
    }

    /// Moves a workspace up (-1) or down (+1) in the list.
    func move(_ workspace: Workspace, by offset: Int) {
        guard let index = workspaces.firstIndex(where: { $0 === workspace }) else { return }
        let destination = index + offset
        guard workspaces.indices.contains(destination) else { return }
        workspaces.swapAt(index, destination)
        persist()
    }

    var canDelete: Bool { workspaces.count > 1 }

    /// Deletes a workspace and terminates its shells. Returns the workspace
    /// that should replace it on screens that were showing it.
    @discardableResult
    func delete(_ workspace: Workspace) -> Workspace? {
        guard canDelete, let index = workspaces.firstIndex(where: { $0 === workspace }) else { return nil }
        workspaces.remove(at: index)
        workspace.onChange = nil
        workspace.terminateAll()
        persist()
        return workspaces[max(0, index - 1)]
    }

    /// Saves everything, including each tab's current folder.
    func persist() {
        let saveTabs = restoresTabs()
        file.save(workspaces.map {
            WorkspaceRecord(
                id: $0.id,
                name: $0.name,
                hotkey: $0.hotkey,
                directory: $0.directory,
                startupCommand: $0.startupCommand,
                tabs: saveTabs ? $0.tabRecords : nil,
                activeIndex: saveTabs ? $0.savedActiveIndex : nil
            )
        })
    }

    private func observe(_ workspace: Workspace) {
        workspace.onChange = { [weak self] in self?.persist() }
    }

    private func nextDefaultName() -> String {
        let names = Set(workspaces.map(\.name))
        if !names.contains("Main") { return "Main" }
        return (2...).lazy.map { "Workspace \($0)" }.first { !names.contains($0) }!
    }
}
