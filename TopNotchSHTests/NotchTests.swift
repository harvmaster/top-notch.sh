import XCTest
@testable import TopNotchSH

final class ScreenGeometryTests: XCTestCase {
    private let laptop = ScreenGeometry(
        id: "laptop", name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        notchHeight: 38, notchWidth: 190, menuBarHeight: 38
    )
    private let monitor = ScreenGeometry(
        id: "monitor", name: "Studio", frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
        notchHeight: 0, notchWidth: 200, menuBarHeight: 25
    )

    func testClosedSizeOnNotchedDisplay() {
        var sizing = SizingSettings()
        XCTAssertEqual(laptop.closedSize(for: sizing), CGSize(width: 190, height: 38))

        sizing.notchedHeightMode = .custom
        sizing.notchedCustomHeight = 44
        XCTAssertEqual(laptop.closedSize(for: sizing).height, 44)
    }

    func testClosedSizeOnExternalDisplay() {
        var sizing = SizingSettings()
        XCTAssertEqual(monitor.closedSize(for: sizing), CGSize(width: 220, height: 25))

        // "Match notch" has no meaning without a notch; it falls back to the menu bar.
        sizing.externalHeightMode = .matchNotch
        XCTAssertEqual(monitor.closedSize(for: sizing).height, 25)
    }

    func testHeaderClearsTheHardwareNotch() {
        XCTAssertEqual(laptop.headerHeight, 38)
        XCTAssertEqual(monitor.headerHeight, ScreenGeometry.externalHeaderHeight)
    }

    func testOpenSizeIsClamped() {
        XCTAssertEqual(laptop.clampOpenSize(CGSize(width: 10, height: 10)), ScreenGeometry.minimumOpenSize)
        XCTAssertEqual(laptop.clampOpenSize(CGSize(width: 5000, height: 5000)), CGSize(width: 1472, height: 942))
    }

    func testWindowFrameHangsFromTopCenter() {
        let frame = monitor.windowFrame(contentSize: CGSize(width: 600, height: 300), margin: 20)
        XCTAssertEqual(frame, CGRect(x: 1512 + 1280 - 320, y: 1440 - 320, width: 640, height: 320))
    }
}

@MainActor
final class WorkspaceTests: XCTestCase {
    private var settings: SettingsStore!
    private var config: ConfigDirectory!

    override func setUp() async throws {
        config = temporaryConfig()
        settings = SettingsStore(file: config.settings)
    }

    /// Records what each new session was asked for. Sessions are never
    /// started, so no shells are spawned.
    private var launches: [(directory: String?, command: String?)] = []

    private var factory: Workspace.SessionFactory {
        { [unowned self] directory, command in
            self.launches.append((directory, command))
            return TerminalSession(settings: self.settings, directory: directory)
        }
    }

    private func makeWorkspace() -> Workspace {
        Workspace(name: "Test", makeSession: factory)
    }

    func testWorkspaceIsLazyUntilShown() {
        let workspace = makeWorkspace()
        XCTAssertTrue(workspace.tabs.isEmpty)
        workspace.ensureTab()
        workspace.ensureTab()
        XCTAssertEqual(workspace.tabs.count, 1)
    }

    func testNewTabBecomesActive() {
        let workspace = makeWorkspace()
        workspace.newTab()
        workspace.newTab()
        XCTAssertEqual(workspace.activeIndex, 1)
    }

    func testClosingActiveTabSelectsNeighbour() {
        let workspace = makeWorkspace()
        (0..<3).forEach { _ in workspace.newTab() }
        let ids = workspace.tabs.map(\.id)

        workspace.selectTab(ids[1])
        workspace.closeActiveTab()
        XCTAssertEqual(workspace.activeTabID, ids[2])

        workspace.closeActiveTab()
        XCTAssertEqual(workspace.activeTabID, ids[0])
    }

    func testClosingLastTabReplacesIt() {
        let workspace = makeWorkspace()
        workspace.newTab()
        let original = workspace.activeTabID
        workspace.closeActiveTab()
        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertNotEqual(workspace.activeTabID, original)
    }

    func testTabNavigationWraps() {
        let workspace = makeWorkspace()
        (0..<3).forEach { _ in workspace.newTab() }
        workspace.selectTab(offset: 1)
        XCTAssertEqual(workspace.activeIndex, 0)
        workspace.selectTab(offset: -1)
        XCTAssertEqual(workspace.activeIndex, 2)
        workspace.selectTab(at: 1)
        XCTAssertEqual(workspace.activeIndex, 1)
        workspace.selectTab(at: 8)
        XCTAssertEqual(workspace.activeIndex, 1)
    }

    func testMovingTabKeepsSelection() {
        let workspace = makeWorkspace()
        (0..<3).forEach { _ in workspace.newTab() }
        let active = workspace.activeTabID!
        workspace.moveTab(active, to: 0)
        XCTAssertEqual(workspace.tabs.first?.id, active)
        XCTAssertEqual(workspace.activeTabID, active)
    }

    func testDetachRemovesWithoutClosing() {
        let workspace = makeWorkspace()
        workspace.newTab()
        workspace.newTab()
        let detached = workspace.detachTab(workspace.activeTabID!)
        XCTAssertNotNil(detached)
        XCTAssertNil(detached?.onExit)
        XCTAssertEqual(workspace.tabs.count, 1)
    }

    func testStorePersistsNamesAndHotkeys() {
        let store = WorkspaceStore(file: config.workspaces, makeSession: factory)
        XCTAssertEqual(store.workspaces.map(\.name), ["Main"])

        let second = store.create()
        XCTAssertEqual(second.name, "Workspace 2")
        store.rename(second, to: "  Servers ")
        store.setHotkey(.command(1), for: second)

        let reloaded = WorkspaceStore(file: config.workspaces, makeSession: factory)
        XCTAssertEqual(reloaded.workspaces.map(\.name), ["Main", "Servers"])
        XCTAssertEqual(reloaded.workspaces.last?.hotkey, .command(1))
    }

    func testRestoresRememberedTabsLazily() {
        let workspace = Workspace(
            name: "Restored",
            restoring: [TabRecord(directory: "/usr", name: "logs"), TabRecord(directory: "/tmp", name: nil)],
            activeIndex: 1,
            makeSession: factory
        )
        XCTAssertTrue(workspace.tabs.isEmpty)
        XCTAssertEqual(workspace.tabRecords.count, 2, "unopened tabs are still saved")

        workspace.ensureTab()
        XCTAssertEqual(launches.map(\.directory), ["/usr", "/tmp"])
        XCTAssertEqual(workspace.tabs.map(\.customName), ["logs", nil])
        XCTAssertEqual(workspace.activeIndex, 1)
    }

    func testWorkspaceFolderAndCommandApplyToNewTabs() {
        let workspace = Workspace(name: "Servers", directory: "/var", startupCommand: "ssh box", makeSession: factory)
        workspace.ensureTab()
        XCTAssertEqual(launches.first?.directory, "/var")
        XCTAssertEqual(launches.first?.command, "ssh box")
    }

    func testReopenClosedTab() {
        let workspace = makeWorkspace()
        workspace.newTab()
        workspace.newTab()
        workspace.renameTab(workspace.activeTabID!, to: "build")
        XCTAssertFalse(workspace.canReopenClosedTab)

        workspace.closeActiveTab()
        XCTAssertTrue(workspace.canReopenClosedTab)
        workspace.reopenClosedTab()
        XCTAssertEqual(workspace.tabs.count, 2)
        XCTAssertEqual(workspace.activeTab?.customName, "build")
        XCTAssertFalse(workspace.canReopenClosedTab)
    }

    func testRenamingTabs() {
        let workspace = makeWorkspace()
        workspace.newTab()
        let id = workspace.activeTabID!
        workspace.renameTab(id, to: "  api  ")
        XCTAssertEqual(workspace.activeTab?.displayTitle, "api")
        workspace.renameTab(id, to: "")
        XCTAssertNil(workspace.activeTab?.customName)
        XCTAssertEqual(workspace.activeTab?.displayTitle, workspace.activeTab?.title)
    }

    func testCloseOtherTabs() {
        let workspace = makeWorkspace()
        (0..<3).forEach { _ in workspace.newTab() }
        let keep = workspace.tabs[1].id
        workspace.closeOtherTabs(than: keep)
        XCTAssertEqual(workspace.tabs.map(\.id), [keep])
    }

    func testStorePersistsTabsFoldersAndCommands() {
        let store = WorkspaceStore(file: config.workspaces, makeSession: factory)
        let main = store.primary
        store.setDirectory("~/Projects", for: main)
        store.setStartupCommand("  ", for: main)
        main.ensureTab()
        main.renameTab(main.activeTabID!, to: "editor")
        store.persist()

        let reloaded = WorkspaceStore(file: config.workspaces, makeSession: factory)
        XCTAssertEqual(reloaded.primary.directory, "~/Projects")
        XCTAssertNil(reloaded.primary.startupCommand, "blank commands are not saved")
        XCTAssertEqual(reloaded.primary.tabRecords.map(\.name), ["editor"])

        let fresh = WorkspaceStore(file: config.workspaces, restoresTabs: { false }, makeSession: factory)
        XCTAssertTrue(fresh.primary.tabRecords.isEmpty, "restore can be turned off")
    }

    func testMovingWorkspaces() {
        let store = WorkspaceStore(file: config.workspaces, makeSession: factory)
        let second = store.create()
        store.move(second, by: -1)
        XCTAssertTrue(store.workspaces.first === second)
        store.move(second, by: -1)
        XCTAssertTrue(store.workspaces.first === second, "can't move past the top")
    }

    func testDeleteKeepsOneWorkspaceAndReturnsFallback() {
        let store = WorkspaceStore(file: config.workspaces, makeSession: factory)
        let main = store.primary
        XCTAssertNil(store.delete(main))

        let other = store.create()
        XCTAssertTrue(store.delete(other) === main)
        XCTAssertEqual(store.workspace(main.id, offset: 1).id, main.id)
    }
}

final class TabDragTests: XCTestCase {
    /// Three 100pt tabs with 4pt gaps: [0–100] [104–204] [208–308].
    private let order = [1, 2, 3]
    private let frames: [Int: CGRect] = [
        1: CGRect(x: 0, y: 0, width: 100, height: 22),
        2: CGRect(x: 104, y: 0, width: 100, height: 22),
        3: CGRect(x: 208, y: 0, width: 100, height: 22),
    ]

    private func drag(_ id: Int, by translation: CGFloat) -> TabDrag<Int> {
        var drag = TabDrag(id: id, order: order, frames: frames, spacing: 4)!
        drag.translation = translation
        return drag
    }

    func testSmallMovesKeepTheSlot() {
        XCTAssertEqual(drag(1, by: 40).dropIndex, 0)
        XCTAssertEqual(drag(2, by: -40).dropIndex, 1)
    }

    func testCrossingANeighboursCentreTakesItsSlot() {
        XCTAssertEqual(drag(1, by: 110).dropIndex, 1)
        XCTAssertEqual(drag(1, by: 260).dropIndex, 2)
        XCTAssertEqual(drag(3, by: -160).dropIndex, 1)
    }

    func testNeighboursSlideAsideToPreviewTheOrder() {
        let right = drag(1, by: 260)
        XCTAssertEqual(right.offset(for: 2, dropIndex: 2), -104)
        XCTAssertEqual(right.offset(for: 3, dropIndex: 2), -104)
        XCTAssertEqual(right.offset(for: 1, dropIndex: 2), 208)

        let left = drag(3, by: -160)
        XCTAssertEqual(left.offset(for: 1, dropIndex: 1), 0)
        XCTAssertEqual(left.offset(for: 2, dropIndex: 1), 104)
    }

    func testDraggedTabCannotLeaveTheRow() {
        XCTAssertEqual(drag(1, by: -80).offset(for: 1, dropIndex: 0), 0)
        XCTAssertEqual(drag(1, by: 900).offset(for: 1, dropIndex: 2), 208)
    }

    func testSettlingLandsExactlyInTheSlot() {
        XCTAssertEqual(drag(1, by: 130).settledTranslation(dropIndex: 1), 104)
        XCTAssertEqual(drag(3, by: -170).settledTranslation(dropIndex: 1), -104)
        XCTAssertEqual(drag(2, by: 10).settledTranslation(dropIndex: 1), 0)
    }

    func testRequiresMeasuredFrames() {
        XCTAssertNil(TabDrag(id: 1, order: order, frames: [1: .zero], spacing: 4))
    }
}
