import AppKit
import SwiftUI

/// A background color at the user's chosen opacity, optionally blurring
/// whatever is behind the window.
struct PanelBackground: View {
    let color: NSColor
    @EnvironmentObject private var settingsStore: SettingsStore

    var body: some View {
        let appearance = settingsStore.settings.appearance
        let isTranslucent = appearance.backgroundOpacity < 1

        ZStack {
            if isTranslucent && appearance.backgroundBlur {
                BehindWindowBlur()
            }
            Color(nsColor: color).opacity(appearance.backgroundOpacity)
        }
    }
}

private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
