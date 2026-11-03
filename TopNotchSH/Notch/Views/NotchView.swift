import SwiftUI

/// Root view of a notch panel. Draws the black notch shape at the controller's
/// (animated) size and swaps between closed and open content.
struct NotchView: View {
    @ObservedObject var controller: NotchController
    @EnvironmentObject private var settingsStore: SettingsStore

    var body: some View {
        let appearance = settingsStore.settings.appearance
        let isOpen = controller.isOpen

        ZStack(alignment: .top) {
            if isOpen {
                OpenNotchView(controller: controller, workspace: controller.workspace)
                    .frame(width: controller.openLayoutSize.width, height: controller.openLayoutSize.height)
                    .transition(.opacity.animation(.easeOut(duration: 0.2)))
            } else {
                ClosedNotchView(controller: controller, workspace: controller.workspace)
                    .transition(.opacity.animation(.easeIn(duration: 0.12)))
            }
        }
        .frame(width: controller.size.width, height: controller.size.height, alignment: .top)
        .background(.black)
        .overlay(alignment: .bottomTrailing) {
            if isOpen {
                ResizeHandle(controller: controller)
            }
        }
        .clipShape(isOpen ? NotchShape.open(cornerRadius: appearance.openCornerRadius) : NotchShape.closed)
        .shadow(
            color: .black.opacity(isOpen && appearance.shadowEnabled ? appearance.shadowOpacity : 0),
            radius: appearance.shadowRadius
        )
        .opacity(appearance.opacity)
        .blur(radius: appearance.blurRadius)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }
}

/// The resting notch: blends into the hardware notch, or shows the active tab
/// title as a small pill on displays without one. Click to open.
private struct ClosedNotchView: View {
    @ObservedObject var controller: NotchController
    @ObservedObject var workspace: Workspace
    @EnvironmentObject private var settingsStore: SettingsStore

    var body: some View {
        ZStack {
            if settingsStore.settings.appearance.showsTitleWhenClosed, !controller.geometry.hasNotch {
                Group {
                    if let tab = workspace.activeTab {
                        SessionTitle(session: tab)
                    } else {
                        Text(workspace.name)
                    }
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 16)
            }
        }
        .frame(width: controller.size.width, height: controller.size.height)
        .contentShape(Rectangle())
        .onTapGesture { controller.open() }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Open terminal")
    }
}

struct SessionTitle: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        Text(session.title)
    }
}

/// Bottom-right grip. Width resizes symmetrically because the panel is centered.
private struct ResizeHandle: View {
    let controller: NotchController

    var body: some View {
        Grip()
            .stroke(.white.opacity(0.3), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            .frame(width: 10, height: 10)
            .padding(9)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { _ in controller.resizeToPointer() }
                    .onEnded { _ in controller.endResize() }
            )
            .help("Drag to resize")
    }

    private struct Grip: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            for inset in [0.0, 4.0, 8.0] {
                path.move(to: CGPoint(x: rect.minX + inset, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + inset))
            }
            return path
        }
    }
}
