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
    private var defaults: UserDefaults!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "TopNotchSHTests.\(UUID().uuidString)")
        settings = SettingsStore(defaults: defaults)
    }

    /// Sessions are never started, so no shells are spawned.
    private func makeWorkspace() -> Workspace {
        Workspace(name: "Test") { [settings] in TerminalSession(settings: settings!, directory: $0) }
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
        let factory: Workspace.SessionFactory = { [settings] in TerminalSession(settings: settings!, directory: $0) }
        let store = WorkspaceStore(defaults: defaults, makeSession: factory)
        XCTAssertEqual(store.workspaces.map(\.name), ["Main"])

        let second = store.create()
        XCTAssertEqual(second.name, "Workspace 2")
        store.rename(second, to: "  Servers ")
        store.setHotkey(.command(1), for: second)

        let reloaded = WorkspaceStore(defaults: defaults, makeSession: factory)
        XCTAssertEqual(reloaded.workspaces.map(\.name), ["Main", "Servers"])
        XCTAssertEqual(reloaded.workspaces.last?.hotkey, .command(1))
    }

    func testDeleteKeepsOneWorkspaceAndReturnsFallback() {
        let store = WorkspaceStore(defaults: defaults) { [settings] in TerminalSession(settings: settings!, directory: $0) }
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
