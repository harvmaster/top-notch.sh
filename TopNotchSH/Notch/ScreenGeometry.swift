import AppKit

typealias ScreenID = String

/// A snapshot of the measurements of one display that the notch cares about.
struct ScreenGeometry: Equatable {
    static let minimumOpenSize = CGSize(width: 320, height: 140)
    static let fallbackNotchWidth: CGFloat = 200
    static let fallbackMenuBarHeight: CGFloat = 24
    static let externalHeaderHeight: CGFloat = 30

    var id: ScreenID
    var name: String
    var frame: CGRect
    /// Height of the camera housing; zero on displays without a notch.
    var notchHeight: CGFloat
    var notchWidth: CGFloat
    var menuBarHeight: CGFloat

    var hasNotch: Bool { notchHeight > 0 }

    /// Height of the open panel's header row. On notched displays it matches the
    /// camera housing, so the terminal always starts below the hardware notch.
    var headerHeight: CGFloat {
        hasNotch ? notchHeight : Self.externalHeaderHeight
    }

    func closedSize(for sizing: SizingSettings) -> CGSize {
        let height: CGFloat
        let mode = hasNotch ? sizing.notchedHeightMode : sizing.externalHeightMode
        switch mode {
        case .matchNotch where hasNotch:
            height = notchHeight
        case .matchNotch, .matchMenuBar:
            height = menuBarHeight
        case .custom:
            height = hasNotch ? sizing.notchedCustomHeight : sizing.externalCustomHeight
        }
        let width = hasNotch ? notchWidth : sizing.externalClosedWidth
        return CGSize(width: width, height: height)
    }

    func openSize(for sizing: SizingSettings) -> CGSize {
        clampOpenSize(sizing.openSize)
    }

    func clampOpenSize(_ size: CGSize) -> CGSize {
        let maximum = CGSize(
            width: max(Self.minimumOpenSize.width, frame.width - 40),
            height: max(Self.minimumOpenSize.height, frame.height - 40)
        )
        return CGSize(
            width: size.width.clamped(to: Self.minimumOpenSize.width...maximum.width).rounded(),
            height: size.height.clamped(to: Self.minimumOpenSize.height...maximum.height).rounded()
        )
    }

    /// Window frame for content of `size` hanging from the top-center of the
    /// screen, with `margin` around the sides and bottom for the shadow.
    func windowFrame(contentSize size: CGSize, margin: CGFloat) -> CGRect {
        let width = size.width + margin * 2
        let height = size.height + margin
        return CGRect(
            x: (frame.midX - width / 2).rounded(),
            y: frame.maxY - height,
            width: width,
            height: height
        )
    }
}

extension ScreenGeometry {
    init(screen: NSScreen) {
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        let notchWidth: CGFloat
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = screen.frame.width - left.width - right.width + 4
        } else {
            notchWidth = Self.fallbackNotchWidth
        }

        self.init(
            id: screen.displayID,
            name: screen.localizedName,
            frame: screen.frame,
            notchHeight: screen.safeAreaInsets.top,
            notchWidth: notchWidth,
            menuBarHeight: menuBarHeight > 0 ? menuBarHeight : Self.fallbackMenuBarHeight
        )
    }
}

extension NSScreen {
    /// Stable identifier for a display that survives reconnects and reboots.
    var displayID: ScreenID {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() else {
            return localizedName
        }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
