import AppKit
import Combine
import SwiftUI

@MainActor
protocol NotchControllerDelegate: AnyObject {
    func notchWillOpen(_ controller: NotchController)
    func notchDidClose(_ controller: NotchController)
    func notch(_ controller: NotchController, perform command: Command)
}

/// Owns one screen's notch: its open/closed phase, its size, the workspace it
/// shows, and the panel that renders it.
///
/// All motion goes through `transition(to:size:animation:)`, which grows the
/// panel before an animation and shrinks it afterwards, so a closed notch only
/// ever covers the notch itself.
@MainActor
final class NotchController: ObservableObject {
    enum Phase {
        case closed
        case open
    }

    @Published private(set) var phase = Phase.closed
    @Published private(set) var size: CGSize
    /// The size open content is laid out at. It jumps straight to the target
    /// while `size` animates, so the terminal reflows once per transition
    /// instead of on every frame; the animating shape clips it.
    @Published private(set) var openLayoutSize: CGSize
    @Published private(set) var geometry: ScreenGeometry
    @Published private(set) var workspace: Workspace
    @Published private(set) var isResizing = false
    /// A pinned notch stays open when another app takes focus.
    @Published private(set) var isPinned = false
    /// Activity in the shown workspace, displayed beside the closed notch.
    @Published private(set) var activity: SessionActivity?

    /// Extra width on each side of the closed notch for the activity indicator.
    static let indicatorWidth: CGFloat = 40
    /// Clear space between the indicator and the notch's visible edge.
    static let indicatorInset: CGFloat = 10

    weak var delegate: NotchControllerDelegate?

    private let settings: SettingsStore
    private(set) var panel = NotchPanel()
    private let canvas: NotchCanvasView
    private var transitionID = 0
    private var resizeOrigin: (size: CGSize, mouse: CGPoint)?
    private var activitySubscription: AnyCancellable?

    init(geometry: ScreenGeometry, workspace: Workspace, settings: SettingsStore, workspaces: WorkspaceStore) {
        self.geometry = geometry
        self.workspace = workspace
        self.settings = settings
        size = geometry.closedSize(for: settings.settings.sizing)
        openLayoutSize = geometry.openSize(for: settings.settings.sizing)

        canvas = NotchCanvasView(canvasSize: geometry.frame.size)
        // As the window's direct content view, NSHostingView would resize the
        // window to fit its content and fight the frame management here.
        canvas.host(
            NotchHostingView(
                rootView: NotchView(controller: self)
                    .environmentObject(settings)
                    .environmentObject(workspaces)
            )
        )
        attach(to: panel)
        setHiddenFromScreenSharing(settings.settings.general.hideFromScreenSharing)
        fitPanel(to: size, margin: 0)
        panel.orderFrontRegardless()
        observeActivity()
    }

    var id: ScreenID { geometry.id }
    var isOpen: Bool { phase == .open }
    var isKey: Bool { panel.isKeyWindow }

    // MARK: - Open / close

    func open() {
        guard phase == .closed else { return }
        delegate?.notchWillOpen(self)
        workspace.ensureTab()

        panel.isOpen = true
        transition(to: .open, size: geometry.openSize(for: settings.settings.sizing), animation: openAnimation)
        focus()
    }

    /// Brings an open notch's terminal to the front and gives it the keyboard.
    func focus() {
        guard isOpen else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        workspace.activeTab?.focus()
    }

    func close() {
        guard phase == .open else { return }
        endResize()
        isPinned = false
        panel.isOpen = false
        transition(to: .closed, size: closedSize, animation: closeAnimation)
        delegate?.notchDidClose(self)
    }

    func togglePin() {
        guard isOpen else { return }
        isPinned.toggle()
    }

    func setHiddenFromScreenSharing(_ hidden: Bool) {
        guard !panel.setHiddenFromScreenSharing(hidden) else { return }
        // macOS won't let a hidden window be shared again, so swap in a new
        // panel showing the same content.
        let old = panel
        let wasKey = old.isKeyWindow
        old.onResignKey = nil
        old.contentView = nil
        panel = NotchPanel()
        panel.isOpen = old.isOpen
        panel.setFrame(old.frame, display: false)
        attach(to: panel)
        panel.orderFrontRegardless()
        old.orderOut(nil)
        old.close()
        if wasKey {
            focus()
        }
    }

    private func attach(to panel: NotchPanel) {
        panel.contentView = canvas
        panel.onResignKey = { [weak self] in self?.focusLost() }
    }

    func toggle() {
        isOpen ? close() : open()
    }

    func perform(_ command: Command) {
        delegate?.notch(self, perform: command)
    }

    // MARK: - Content

    func show(_ workspace: Workspace) {
        guard workspace !== self.workspace else { return }
        self.workspace = workspace
        if isOpen {
            workspace.ensureTab()
        }
        observeActivity()
    }

    /// The closed notch widens to make room for an indicator when a tab in
    /// the shown workspace needs attention.
    private var closedSize: CGSize {
        var size = geometry.closedSize(for: settings.settings.sizing)
        if activity != nil {
            size.width += Self.indicatorWidth * 2
        }
        return size
    }

    private func observeActivity() {
        activitySubscription = workspace.$activity
            .removeDuplicates()
            .sink { [weak self] activity in
                guard let self else { return }
                let wasShowing = self.activity != nil
                self.activity = activity
                if !self.isOpen, wasShowing != (activity != nil) {
                    self.transition(to: .closed, size: self.closedSize, animation: self.openAnimation)
                }
            }
    }

    /// Re-measures after a display or settings change and animates to the new size.
    func refresh(geometry newGeometry: ScreenGeometry? = nil) {
        if let newGeometry {
            geometry = newGeometry
            canvas.canvasSize = newGeometry.frame.size
        }
        guard !isResizing else { return }

        let sizing = settings.settings.sizing
        let target = isOpen ? geometry.openSize(for: sizing) : closedSize
        guard target != size else {
            fitPanel(to: size, margin: restingMargin)
            return
        }
        transition(to: phase, size: target, animation: isOpen ? resizeAnimation : nil)
    }

    func tearDown() {
        transitionID += 1
        panel.onResignKey = nil
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
    }

    // MARK: - Interactive resize

    /// Tracks the pointer in screen coordinates, since the panel itself moves
    /// while being resized. Width grows symmetrically around the center.
    func resizeToPointer() {
        let mouse = NSEvent.mouseLocation
        if resizeOrigin == nil {
            resizeOrigin = (size, mouse)
            isResizing = true
            transitionID += 1
        }
        guard let origin = resizeOrigin else { return }

        size = geometry.clampOpenSize(CGSize(
            width: origin.size.width + (mouse.x - origin.mouse.x) * 2,
            height: origin.size.height + (origin.mouse.y - mouse.y)
        ))
        openLayoutSize = size
        fitPanel(to: size, margin: shadowMargin)
    }

    func endResize() {
        guard resizeOrigin != nil else { return }
        resizeOrigin = nil
        isResizing = false
        let size = size
        settings.update {
            $0.sizing.openWidth = size.width
            $0.sizing.openHeight = size.height
        }
    }

    // MARK: - Motion

    private func transition(to phase: Phase, size target: CGSize, animation: Animation?) {
        transitionID += 1
        let id = transitionID
        if phase == .open {
            openLayoutSize = target
        }

        guard let animation else {
            self.phase = phase
            size = target
            fitPanel(to: target, margin: restingMargin)
            return
        }

        // Grow first so nothing is clipped mid-flight; shrink as soon as the
        // motion visibly lands (a spring's long tail would otherwise leave an
        // invisible panel catching clicks for a second after closing).
        fitPanel(
            to: CGSize(width: max(size.width, target.width), height: max(size.height, target.height)),
            margin: shadowMargin
        )
        withAnimation(animation, completionCriteria: .logicallyComplete) {
            self.phase = phase
            self.size = target
        } completion: { [weak self] in
            guard let self, self.transitionID == id else { return }
            self.fitPanel(to: self.size, margin: self.restingMargin)
        }
    }

    private func fitPanel(to contentSize: CGSize, margin: CGFloat) {
        let frame = geometry.windowFrame(contentSize: contentSize, margin: margin)
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: true)
    }

    private func focusLost() {
        guard settings.settings.general.closeOnFocusLoss, !isPinned else { return }
        close()
    }

    private var shadowMargin: CGFloat {
        let appearance = settings.settings.appearance
        return appearance.shadowEnabled ? ceil(appearance.shadowRadius * 2.5) + 4 : 4
    }

    /// The closed notch has no shadow, so its panel hugs the shape exactly and
    /// never steals clicks from the menu bar around it.
    private var restingMargin: CGFloat {
        isOpen ? shadowMargin : 0
    }

    private var openAnimation: Animation {
        let motion = settings.settings.motion
        return .spring(response: motion.openResponse, dampingFraction: motion.openDamping)
    }

    private var closeAnimation: Animation {
        let motion = settings.settings.motion
        return .spring(response: motion.closeResponse, dampingFraction: motion.closeDamping)
    }

    private var resizeAnimation: Animation {
        .easeInOut(duration: settings.settings.motion.resizeDuration)
    }
}
