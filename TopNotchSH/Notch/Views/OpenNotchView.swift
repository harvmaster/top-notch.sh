import SwiftUI

/// The expanded notch: header (workspace + actions), terminal, tab strip.
struct OpenNotchView: View {
    static let tabStripHeight: CGFloat = 30

    @ObservedObject var controller: NotchController
    @ObservedObject var workspace: Workspace
    @EnvironmentObject private var settingsStore: SettingsStore

    var body: some View {
        let settings = settingsStore.settings
        let geometry = controller.geometry
        let insets = settings.padding.insets(hasNotch: geometry.hasNotch)

        VStack(spacing: 0) {
            NotchHeader(controller: controller, workspace: workspace)
                .frame(height: geometry.headerHeight)

            ZStack {
                if let tab = workspace.activeTab {
                    TerminalSurface(session: tab)
                }
            }
            .padding(.top, insets.top)
            .padding(.horizontal, insets.horizontal)
            .padding(.bottom, insets.bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: settings.terminal.theme.palette.backgroundColor))

            TabStrip(workspace: workspace)
                .frame(height: Self.tabStripHeight)
                .padding(.horizontal, max(10, settings.appearance.openCornerRadius * 0.6))
                .padding(.trailing, 18) // room for the resize grip
        }
    }
}

// MARK: - Header

private struct NotchHeader: View {
    let controller: NotchController
    @ObservedObject var workspace: Workspace

    var body: some View {
        let geometry = controller.geometry
        let notchGap = geometry.hasNotch ? geometry.notchWidth : 0
        // Each side gets the space beside the hardware notch, never beneath it.
        let sideWidth = max(0, (controller.openLayoutSize.width - notchGap) / 2 - 16)

        HStack(spacing: 0) {
            WorkspaceMenu(controller: controller, workspace: workspace)
                .frame(maxWidth: sideWidth, alignment: .leading)

            Spacer(minLength: notchGap)

            HStack(spacing: 2) {
                HeaderButton(symbol: "rectangle.portrait.and.arrow.right", help: "Detach tab to window") {
                    controller.perform(.detachTab)
                }
                HeaderButton(symbol: "gearshape", help: "Settings") {
                    controller.perform(.showSettings)
                }
            }
            .frame(maxWidth: sideWidth, alignment: .trailing)
        }
        .padding(.horizontal, 12)
    }
}

private struct HeaderButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Subtle press feedback that suits the black panel.
struct NotchButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.95 : 0.5))
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.white.opacity(configuration.isPressed ? 0.14 : 0))
            )
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Workspace menu

/// Switches, creates, renames and deletes workspaces. Renaming happens inline,
/// so the panel never loses focus to an alert window.
private struct WorkspaceMenu: View {
    let controller: NotchController
    @ObservedObject var workspace: Workspace
    @EnvironmentObject private var workspaces: WorkspaceStore

    @State private var draftName: String?
    @FocusState private var isRenaming: Bool

    var body: some View {
        if let draftName {
            TextField("Workspace name", text: Binding(get: { draftName }, set: { self.draftName = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(0.12)))
                .focused($isRenaming)
                .onSubmit(commitRename)
                .onExitCommand(perform: endRename)
                .onChange(of: isRenaming) { _, focused in
                    if !focused { commitRename() }
                }
                .onAppear { isRenaming = true }
        } else {
            menu
        }
    }

    private var menu: some View {
        Menu {
            ForEach(workspaces.workspaces) { item in
                Toggle(isOn: Binding(
                    get: { item === workspace },
                    set: { _ in controller.perform(.selectWorkspace(item.id)) }
                )) {
                    if let hotkey = item.hotkey {
                        Text("\(item.name)  \(hotkey.displayString)")
                    } else {
                        Text(item.name)
                    }
                }
            }

            Divider()

            Button("New Workspace") { controller.perform(.createWorkspace) }
            Button("Rename “\(workspace.name)”…") { draftName = workspace.name }

            Menu("Delete “\(workspace.name)”") {
                Button("Delete Workspace and Close Its Tabs", role: .destructive) {
                    controller.perform(.deleteWorkspace(workspace.id))
                }
            }
            .disabled(!workspaces.canDelete)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 10, weight: .semibold))
                Text(workspace.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.7)
            }
            .foregroundStyle(.white.opacity(0.72))
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Workspace")
    }

    private func commitRename() {
        if let draftName {
            workspaces.rename(workspace, to: draftName)
        }
        endRename()
    }

    private func endRename() {
        draftName = nil
        workspace.activeTab?.focus()
    }
}
