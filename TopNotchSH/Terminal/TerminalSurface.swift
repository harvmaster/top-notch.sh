import AppKit
import SwiftUI

/// Embeds a session's terminal view in SwiftUI.
///
/// The terminal view is owned by the session, not by SwiftUI, so it survives
/// view rebuilds and can move between the notch and pop-out windows.
struct TerminalSurface: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> TerminalContainerView {
        TerminalContainerView()
    }

    func updateNSView(_ container: TerminalContainerView, context: Context) {
        container.host(session.view)
    }

    static func dismantleNSView(_ container: TerminalContainerView, coordinator: ()) {
        container.host(nil)
    }
}

final class TerminalContainerView: NSView {
    private weak var hosted: NSView?

    func host(_ view: NSView?) {
        guard hosted !== view else { return }
        if hosted?.superview === self {
            hosted?.removeFromSuperview()
        }
        hosted = view
        guard let view else { return }

        view.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        focusIfKey()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusIfKey()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        markSeen()
    }

    /// Whenever a terminal appears in the key window, it takes keyboard focus.
    private func focusIfKey() {
        markSeen()
        guard let window, window.isKeyWindow, let hosted, hosted.superview === self else { return }
        window.makeFirstResponder(hosted)
    }

    /// Showing a terminal clears its pending activity badge.
    private func markSeen() {
        guard window != nil, let terminal = hosted as? SessionTerminalView, terminal.superview === self else { return }
        terminal.session?.markSeen()
    }
}
