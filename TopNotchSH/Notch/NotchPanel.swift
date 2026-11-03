import AppKit
import SwiftUI

/// Borderless panel that floats above the menu bar and hosts one screen's notch.
/// It can only become key (and so receive typing) while the notch is open.
final class NotchPanel: NSPanel {
    var isOpen = false
    var onResignKey: (() -> Void)?

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true
        level = .mainMenu + 3
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { isOpen }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        guard isOpen else { return }
        // Let the new key window settle before deciding to close.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isOpen, !self.isKeyWindow else { return }
            self.onResignKey?()
        }
    }
}

/// The panel's content view. It hosts SwiftUI on a fixed, screen-sized canvas
/// pinned to its top-center, so resizing the panel never changes SwiftUI's
/// layout: the notch stays centered under the camera at every animation frame
/// instead of sliding as the window grows or shrinks.
final class NotchCanvasView: NSView {
    private var hostedView: NSView?

    var canvasSize: CGSize {
        didSet { needsLayout = true }
    }

    init(canvasSize: CGSize) {
        self.canvasSize = canvasSize
        super.init(frame: .zero)
        clipsToBounds = true
    }

    func host(_ view: NSView) {
        hostedView?.removeFromSuperview()
        hostedView = view
        addSubview(view)
        needsLayout = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        hostedView?.frame = CGRect(
            x: ((bounds.width - canvasSize.width) / 2).rounded(),
            y: bounds.height - canvasSize.height,
            width: canvasSize.width,
            height: canvasSize.height
        )
    }
}

/// Hosting view tuned for an overlay: no safe-area insets (which would push
/// content below the camera housing twice), no window-size constraints, and
/// clicks register even when the panel is not key.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        safeAreaRegions = []
        sizingOptions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
