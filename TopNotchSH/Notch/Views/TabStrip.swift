import SwiftUI

/// Tabs of the current workspace, sharing the strip's width like browser tabs.
///
/// Dragging lifts a tab and moves it with the pointer while its neighbours
/// slide aside to preview the new order. The workspace is only reordered once
/// the tab has settled into its slot, so nothing re-lays out mid-drag.
struct TabStrip: View {
    private static let space = "tab-strip"
    private static let spacing: CGFloat = 4
    private static let push = Animation.spring(response: 0.26, dampingFraction: 0.82)
    private static let settle = Animation.spring(response: 0.24, dampingFraction: 0.9)

    @ObservedObject var workspace: Workspace

    @State private var frames: [TerminalSession.ID: CGRect] = [:]
    @State private var drag: TabDrag<TerminalSession.ID>?
    /// Committed separately from `drag.translation` so neighbours animate
    /// when the drop slot changes while the dragged tab tracks the pointer 1:1.
    @State private var dropIndex: Int?

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: Self.spacing) {
                ForEach(workspace.tabs) { tab in
                    tabItem(tab)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .coordinateSpace(name: Self.space)
            .onPreferenceChange(TabFramesKey.self) { frames = $0 }

            Button {
                workspace.newTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(NotchButtonStyle())
            .help("New tab")
            .accessibilityLabel("New tab")
        }
        .padding(.vertical, 4)
    }

    private func tabItem(_ tab: TerminalSession) -> some View {
        let isDragged = drag?.id == tab.id

        return TabItem(
            session: tab,
            isActive: tab.id == workspace.activeTabID,
            isLifted: isDragged,
            canClose: workspace.tabs.count > 1,
            onClose: { workspace.closeTab(tab.id) }
        )
        .frame(minWidth: 44, maxWidth: 200)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: TabFramesKey.self, value: [tab.id: proxy.frame(in: .named(Self.space))])
            }
        }
        .offset(x: offset(for: tab.id))
        .zIndex(isDragged ? 1 : 0)
        .onTapGesture { workspace.selectTab(tab.id) }
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
                .onChanged { dragChanged(tab.id, translation: $0.translation.width) }
                .onEnded { _ in dragEnded() }
        )
    }

    private func offset(for id: TerminalSession.ID) -> CGFloat {
        guard let drag else { return 0 }
        return drag.offset(for: id, dropIndex: dropIndex ?? drag.sourceIndex)
    }

    // MARK: - Dragging

    private func dragChanged(_ id: TerminalSession.ID, translation: CGFloat) {
        if drag == nil {
            guard let started = TabDrag(id: id, order: workspace.tabs.map(\.id), frames: frames, spacing: Self.spacing) else { return }
            workspace.selectTab(id)
            withAnimation(.easeOut(duration: 0.12)) {
                drag = started
            }
            dropIndex = started.sourceIndex
        }
        guard drag?.id == id, !(drag?.isSettling ?? true) else { return }

        drag?.translation = translation
        if let target = drag?.dropIndex, target != dropIndex {
            withAnimation(Self.push) {
                dropIndex = target
            }
        }
    }

    private func dragEnded() {
        guard var drag, !drag.isSettling, let dropIndex else { return }
        drag.isSettling = true
        self.drag = drag

        withAnimation(Self.settle) {
            self.drag?.translation = drag.settledTranslation(dropIndex: dropIndex)
        } completion: {
            // Positions after the move match the settled offsets exactly, so
            // commit without animation to avoid any visible jump.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                workspace.moveTab(drag.id, to: dropIndex)
                self.drag = nil
                self.dropIndex = nil
            }
        }
    }
}

/// Geometry for previewing a drag-reorder in a row of tabs. Frames are the
/// tabs' resting positions; nothing moves in the model until the drop.
struct TabDrag<ID: Hashable> {
    let id: ID
    let order: [ID]
    let frames: [ID: CGRect]
    let spacing: CGFloat
    let sourceIndex: Int
    var translation: CGFloat = 0
    var isSettling = false

    init?(id: ID, order: [ID], frames: [ID: CGRect], spacing: CGFloat) {
        guard let sourceIndex = order.firstIndex(of: id), order.allSatisfy({ frames[$0] != nil }) else { return nil }
        self.id = id
        self.order = order
        self.frames = frames
        self.spacing = spacing
        self.sourceIndex = sourceIndex
    }

    private var draggedFrame: CGRect { frames[id]! }

    /// Pointer translation, clamped so the tab can't leave the row.
    private var clampedTranslation: CGFloat {
        let lower = frames[order.first!]!.minX - draggedFrame.minX
        let upper = frames[order.last!]!.maxX - draggedFrame.maxX
        return translation.clamped(to: lower...upper)
    }

    /// The slot the dragged tab would drop into: past every tab whose centre
    /// its own centre has reached. Reaching counts, so a tab pushed against
    /// the end of the row can always take the last slot.
    var dropIndex: Int {
        let center = draggedFrame.midX + clampedTranslation
        return order.enumerated().filter { index, tab in
            guard tab != id else { return false }
            let mid = frames[tab]!.midX
            return index > sourceIndex ? mid <= center : mid < center
        }.count
    }

    func offset(for tab: ID, dropIndex: Int) -> CGFloat {
        if tab == id {
            return isSettling ? translation : clampedTranslation
        }
        guard let index = order.firstIndex(of: tab) else { return 0 }
        let shift = draggedFrame.width + spacing
        if sourceIndex < dropIndex, (sourceIndex + 1...dropIndex).contains(index) {
            return -shift
        }
        if dropIndex < sourceIndex, (dropIndex..<sourceIndex).contains(index) {
            return shift
        }
        return 0
    }

    /// The translation that lands the dragged tab exactly in its drop slot.
    func settledTranslation(dropIndex: Int) -> CGFloat {
        if dropIndex > sourceIndex {
            return frames[order[dropIndex]]!.maxX - draggedFrame.maxX
        }
        return frames[order[dropIndex]]!.minX - draggedFrame.minX
    }
}

private struct TabItem: View {
    @ObservedObject var session: TerminalSession
    let isActive: Bool
    let isLifted: Bool
    let canClose: Bool
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Text(session.title)
                .font(.system(size: 11, weight: isActive ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)

            if isActive && canClose && !isLifted {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(NotchButtonStyle())
                .help("Close tab")
            }
        }
        .foregroundStyle(.white.opacity(isActive ? 0.95 : 0.5))
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isLifted ? Color(white: 0.2) : .white.opacity(isActive ? 0.13 : 0))
                .shadow(color: .black.opacity(isLifted ? 0.6 : 0), radius: 6, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.white.opacity(isLifted ? 0.18 : 0), lineWidth: 0.5)
        )
        .scaleEffect(isLifted ? 1.05 : 1)
        .contentShape(Rectangle())
    }
}

private struct TabFramesKey: PreferenceKey {
    static let defaultValue: [TerminalSession.ID: CGRect] = [:]

    static func reduce(value: inout [TerminalSession.ID: CGRect], nextValue: () -> [TerminalSession.ID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
