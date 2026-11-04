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
        .background {
            // Closed, the notch must stay solid black to blend with the hardware.
            if isOpen {
                PanelBackground(color: settingsStore.settings.terminal.theme.palette.backgroundColor)
                    .transition(.opacity)
            } else {
                Color.black
            }
        }
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
    @State private var isDropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            if let activity = controller.activity {
                ActivityIcon(activity: activity)
                    // The notch's visible edge sits `topRadius` in from the panel edge.
                    .padding(.leading, NotchShape.closed.topRadius + NotchController.indicatorInset)
                    .frame(width: NotchController.indicatorWidth, alignment: .leading)
                    .transition(.scale.combined(with: .opacity))
            }

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
            .frame(maxWidth: .infinity)

            if let activity = controller.activity {
                PulsingDot(color: activity.color)
                    .frame(width: 14)
                    .padding(.trailing, NotchShape.closed.topRadius + NotchController.indicatorInset)
                    .frame(width: NotchController.indicatorWidth, alignment: .trailing)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: controller.size.width, height: controller.size.height)
        .contentShape(Rectangle())
        .onTapGesture { controller.open() }
        // Dragging files onto the closed notch opens it, so they can be dropped on the terminal.
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { _ in false }
        .onChange(of: isDropTargeted) { _, targeted in
            if targeted { controller.open() }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(controller.activity.map { "Open terminal, \($0.accessibilityLabel)" } ?? "Open terminal")
    }
}

extension SessionActivity {
    var color: Color {
        switch self {
        case .output: .blue
        case .finished: .green
        case .bell: .orange
        }
    }

    var symbol: String {
        switch self {
        case .output: "text.bubble.fill"
        case .finished: "checkmark.circle.fill"
        case .bell: "bell.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .output: "new output"
        case .finished: "a command finished"
        case .bell: "a tab rang the bell"
        }
    }
}

private struct ActivityIcon: View {
    let activity: SessionActivity

    var body: some View {
        Image(systemName: activity.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(activity.color)
            .shadow(color: activity.color.opacity(0.8), radius: 4)
    }
}

private struct PulsingDot: View {
    let color: Color
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .shadow(color: color, radius: isPulsing ? 5 : 1)
            .scaleEffect(isPulsing ? 1.25 : 0.85)
            .opacity(isPulsing ? 1 : 0.6)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}

struct SessionTitle: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        Text(session.displayTitle)
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
