import SwiftUI

struct SettingsView: View {
    enum Page: String, CaseIterable, Identifiable {
        case general, notch, appearance, motion, terminal, hotkeys, workspaces, about

        var id: String { rawValue }
        var title: String { rawValue.capitalized }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .notch: "rectangle.topthird.inset.filled"
            case .appearance: "paintbrush"
            case .motion: "wind"
            case .terminal: "apple.terminal"
            case .hotkeys: "keyboard"
            case .workspaces: "square.stack.3d.up"
            case .about: "info.circle"
            }
        }
    }

    @State private var page: Page

    init(page: Page = .general) {
        _page = State(initialValue: page)
    }

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { page in
                Label(page.title, systemImage: page.symbol).tag(page)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
        } detail: {
            detail
                .formStyle(.grouped)
                .navigationTitle(page.title)
        }
        .frame(minWidth: 680, minHeight: 460)
    }

    @ViewBuilder
    private var detail: some View {
        switch page {
        case .general: GeneralPage()
        case .notch: NotchPage()
        case .appearance: AppearancePage()
        case .motion: MotionPage()
        case .terminal: TerminalPage()
        case .hotkeys: HotkeysPage()
        case .workspaces: WorkspacesPage()
        case .about: AboutPage()
        }
    }
}

// MARK: - General

private struct GeneralPage: View {
    @EnvironmentObject private var store: SettingsStore
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        LaunchAtLogin.setEnabled(enabled)
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                Toggle("Show menu bar icon", isOn: store.binding(\.general.showMenuBarIcon))
                Caption("When hidden, open Top NotchSH again from Finder or Spotlight to reach settings.")
            }
            Section("Behavior") {
                Toggle("Show on all displays", isOn: store.binding(\.general.showOnAllDisplays))
                Toggle("Close when another app is focused", isOn: store.binding(\.general.closeOnFocusLoss))
                Caption("Pin the notch (⌘⇧P or the pin button) to keep it open regardless.")
                Toggle("Reopen tabs after restart", isOn: store.binding(\.general.restoreTabs))
                Caption("Tabs come back in their last folders, with their names. Running programs can't be restored.")
            }
            Section("Privacy") {
                Toggle("Hide from screen sharing and recordings", isOn: store.binding(\.general.hideFromScreenSharing))
                Caption("Also available from the menu bar icon, for quick switching before a call.")
            }
            Section {
                Toggle("A tab rings the bell", isOn: store.binding(\.activity.bell))
                Toggle("A long command finishes", isOn: store.binding(\.activity.finishedCommands))
                if store.settings.activity.finishedCommands {
                    SliderRow(
                        title: "Longer than",
                        value: store.binding(\.activity.minimumCommandSeconds),
                        range: 1...120,
                        format: { "\(Int($0.rounded())) s" }
                    )
                }
                Toggle("Any new output", isOn: store.binding(\.activity.output))
            } header: {
                Text("Activity")
            } footer: {
                Caption("When this happens in a tab you aren't looking at, the closed notch widens to show an indicator and the tab gets a dot.")
            }
        }
    }
}

// MARK: - Notch

private struct NotchPage: View {
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var coordinator: NotchCoordinator

    var body: some View {
        let sizing = store.settings.sizing
        let maximum = maximumOpenSize

        Form {
            Section("Open size") {
                SliderRow(title: "Width", value: store.binding(\.sizing.openWidth), range: 320...max(maximum.width, sizing.openWidth), step: 10, format: SliderRow.points)
                SliderRow(title: "Height", value: store.binding(\.sizing.openHeight), range: 140...max(maximum.height, sizing.openHeight), step: 10, format: SliderRow.points)
                Caption("You can also drag the grip in the bottom-right corner of the open notch.")
            }

            SizePresetsSection()

            Section {
                InsetsEditor(insets: store.binding(\.padding.notched))
            } header: {
                Text("Terminal padding · built-in notched display")
            } footer: {
                Caption("Increase the bottom padding if the last line of output is hidden under the tab bar.")
            }

            Section("Terminal padding · other displays") {
                InsetsEditor(insets: store.binding(\.padding.external))
            }

            Section("Closed notch · notched display") {
                Picker("Height", selection: store.binding(\.sizing.notchedHeightMode)) {
                    ForEach(ClosedHeightMode.allCases) { Text($0.title).tag($0) }
                }
                if sizing.notchedHeightMode == .custom {
                    SliderRow(title: "Custom height", value: store.binding(\.sizing.notchedCustomHeight), range: 16...64, format: SliderRow.points)
                }
            }

            Section("Closed notch · other displays") {
                Picker("Height", selection: store.binding(\.sizing.externalHeightMode)) {
                    ForEach([ClosedHeightMode.matchMenuBar, .custom]) { Text($0.title).tag($0) }
                }
                if sizing.externalHeightMode == .custom {
                    SliderRow(title: "Custom height", value: store.binding(\.sizing.externalCustomHeight), range: 16...64, format: SliderRow.points)
                }
                SliderRow(title: "Width", value: store.binding(\.sizing.externalClosedWidth), range: 120...400, step: 10, format: SliderRow.points)
            }
        }
    }

    private var maximumOpenSize: CGSize {
        let largest = coordinator.screens.map(\.frame.size).max { $0.width * $0.height < $1.width * $1.height }
        return CGSize(width: (largest?.width ?? 1600) - 40, height: (largest?.height ?? 900) - 40)
    }
}

private struct SizePresetsSection: View {
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var coordinator: NotchCoordinator

    var body: some View {
        Section {
            ForEach(store.binding(\.sizePresets)) { $preset in
                HStack(spacing: 8) {
                    TextField("Name", text: $preset.name)
                        .labelsHidden()
                        .frame(maxWidth: 120)
                    TextField("Width", value: $preset.width, format: .number)
                        .labelsHidden()
                        .frame(width: 56)
                    Text("×").foregroundStyle(.secondary)
                    TextField("Height", value: $preset.height, format: .number)
                        .labelsHidden()
                        .frame(width: 56)
                    Spacer()
                    HotkeyRecorder(chord: $preset.hotkey, allowsClearing: true)
                    Button("Apply") { coordinator.perform(.applySizePreset(preset)) }
                    Button {
                        store.update { $0.sizePresets.removeAll { $0.id == preset.id } }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove preset")
                }
            }
            HStack {
                Button("Add Current Size") {
                    store.update {
                        $0.sizePresets.append(SizePreset(
                            name: "Preset \($0.sizePresets.count + 1)",
                            width: $0.sizing.openWidth,
                            height: $0.sizing.openHeight,
                            hotkey: SizePreset.suggestedHotkey(excluding: $0.sizePresets)
                        ))
                    }
                }
                Button("Restore Defaults") {
                    store.update { $0.sizePresets = SizePreset.defaults }
                }
            }
        } header: {
            Text("Size presets")
        } footer: {
            Caption("Preset shortcuts work while the notch is open.")
        }
    }
}

// MARK: - Appearance

private struct AppearancePage: View {
    @EnvironmentObject private var store: SettingsStore

    var body: some View {
        Form {
            Section("Panel") {
                SliderRow(title: "Corner radius", value: store.binding(\.appearance.openCornerRadius), range: 0...40, format: SliderRow.points)
                SliderRow(title: "Opacity", value: store.binding(\.appearance.opacity), range: 0.3...1, step: 0.05, format: SliderRow.percent)
                SliderRow(title: "Blur", value: store.binding(\.appearance.blurRadius), range: 0...10, step: 0.5, format: SliderRow.fraction)
                Toggle("Show tab title in closed notch", isOn: store.binding(\.appearance.showsTitleWhenClosed))
                Caption("The title only appears on displays without a camera notch.")
            }
            Section {
                SliderRow(title: "Opacity", value: store.binding(\.appearance.backgroundOpacity), range: 0.3...1, step: 0.05, format: SliderRow.percent)
                Toggle("Blur what's behind", isOn: store.binding(\.appearance.backgroundBlur))
                    .disabled(store.settings.appearance.backgroundOpacity >= 1)
            } header: {
                Text("Background")
            } footer: {
                Caption("Makes only the background translucent; text stays crisp. The closed notch stays solid black.")
            }
            Section("Shadow") {
                Toggle("Shadow", isOn: store.binding(\.appearance.shadowEnabled))
                if store.settings.appearance.shadowEnabled {
                    SliderRow(title: "Radius", value: store.binding(\.appearance.shadowRadius), range: 0...30, format: SliderRow.points)
                    SliderRow(title: "Opacity", value: store.binding(\.appearance.shadowOpacity), range: 0...1, step: 0.05, format: SliderRow.percent)
                }
            }
        }
    }
}

// MARK: - Motion

private struct MotionPage: View {
    @EnvironmentObject private var store: SettingsStore

    var body: some View {
        Form {
            Section {
                SliderRow(title: "Response", value: store.binding(\.motion.openResponse), range: 0.1...1.5, step: 0.01, format: SliderRow.seconds)
                SliderRow(title: "Damping", value: store.binding(\.motion.openDamping), range: 0.1...1.5, step: 0.01, format: SliderRow.fraction)
            } header: {
                Text("Open")
            } footer: {
                Caption("Damping below 1 overshoots for a springy feel; 1 and above settles without bouncing.")
            }
            Section("Close") {
                SliderRow(title: "Response", value: store.binding(\.motion.closeResponse), range: 0.1...1.5, step: 0.01, format: SliderRow.seconds)
                SliderRow(title: "Damping", value: store.binding(\.motion.closeDamping), range: 0.1...1.5, step: 0.01, format: SliderRow.fraction)
            }
            Section("Resize") {
                SliderRow(title: "Duration", value: store.binding(\.motion.resizeDuration), range: 0.05...1.5, step: 0.01, format: SliderRow.seconds)
            }
            Section {
                Button("Restore Defaults") { store.update { $0.motion = MotionSettings() } }
            }
        }
    }
}

// MARK: - Terminal

private struct TerminalPage: View {
    @EnvironmentObject private var store: SettingsStore
    @State private var fonts = TerminalFont.availableMonospaced()

    var body: some View {
        let terminal = store.settings.terminal

        Form {
            Section("Text") {
                Picker("Font", selection: store.binding(\.terminal.fontName)) {
                    Text("System Monospaced").tag("")
                    Divider()
                    ForEach(fonts, id: \.name) { font in
                        Text(font.displayName).tag(font.name)
                    }
                }
                SliderRow(title: "Size", value: store.binding(\.terminal.fontSize), range: TerminalSettings.fontSizeRange, format: SliderRow.points)
                Picker("Cursor", selection: store.binding(\.terminal.cursorShape)) {
                    ForEach(CursorShape.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Blinking cursor", isOn: store.binding(\.terminal.cursorBlinks))
            }

            Section("Theme") {
                Picker("Theme", selection: store.binding(\.terminal.theme)) {
                    ForEach(TerminalTheme.allCases) { Text($0.title).tag($0) }
                }
                ThemePreview(palette: terminal.theme.palette, font: TerminalFont.make(name: terminal.fontName, size: 12))
            }

            Section {
                Toggle("Use Option as Meta key", isOn: store.binding(\.terminal.optionAsMeta))
                TextField("Shell", text: store.binding(\.terminal.shellPath), prompt: Text(Shell.resolve(configuredPath: "")))
                LabeledContent("Scrollback") {
                    TextField("Lines", value: store.binding(\.terminal.scrollbackLines), format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 110)
                }
            } header: {
                Text("Input & shell")
            } footer: {
                Caption("Option as Meta makes ⌥← / ⌥→ jump by word. Shell changes apply to new tabs. Scrollback costs about 2 KB per line at the default width, and only as output fills it: 5,000 lines is about 10 MB for a tab that has used it all.")
            }
        }
    }
}

private struct ThemePreview: View {
    let palette: TerminalTheme.Palette
    let font: NSFont

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            (Text("~/project ").foregroundColor(color(palette.ansi[4]))
                + Text("main ").foregroundColor(color(palette.ansi[5]))
                + Text("❯ ").foregroundColor(color(palette.ansi[2]))
                + Text("ls -la").foregroundColor(Color(nsColor: palette.foregroundColor)))
                .font(Font(font))
            HStack(spacing: 3) {
                ForEach(Array(palette.ansi.enumerated()), id: \.offset) { _, hex in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(color(hex))
                        .frame(height: 14)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: palette.backgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
    }

    private func color(_ hex: UInt32) -> Color {
        Color(nsColor: .hex(hex))
    }
}

// MARK: - Hotkeys

private struct HotkeysPage: View {
    @EnvironmentObject private var store: SettingsStore

    var body: some View {
        Form {
            ForEach(HotkeyAction.Scope.allCases, id: \.self) { scope in
                Section {
                    ForEach(HotkeyAction.allCases.filter { $0.scope == scope }) { action in
                        HStack {
                            Text(action.title)
                            Spacer()
                            HotkeyRecorder(chord: binding(for: action))
                        }
                    }
                    if scope == .notch {
                        LabeledContent("Switch to tab 1–9") { Text("⌘1 … ⌘9").foregroundStyle(.secondary) }
                    }
                } header: {
                    Text(title(for: scope))
                } footer: {
                    if scope == .terminal {
                        Caption("Reset fixes a terminal left in a bad state by a crashed program, e.g. mouse movement printing junk or arrow keys misbehaving.")
                    }
                }
            }
            Section {
                Caption("Terminal editing keys: ⌘← / ⌘→ start and end of line, ⌘⌫ delete line, ⌘L clear screen.")
                Button("Restore Defaults") { store.update { $0.hotkeys = HotkeyAction.defaultBindings } }
            }
        }
    }

    private func binding(for action: HotkeyAction) -> Binding<KeyChord> {
        Binding(
            get: { store.settings.chord(for: action) },
            set: { chord in store.update { $0.hotkeys[action] = chord } }
        )
    }

    private func title(for scope: HotkeyAction.Scope) -> String {
        switch scope {
        case .global: "Global"
        case .notch: "While the notch is open"
        case .terminal: "In any terminal"
        }
    }
}

// MARK: - Workspaces

private struct WorkspacesPage: View {
    @EnvironmentObject private var workspaces: WorkspaceStore
    @EnvironmentObject private var coordinator: NotchCoordinator

    var body: some View {
        Form {
            ForEach(Array(workspaces.workspaces.enumerated()), id: \.element.id) { index, workspace in
                WorkspaceSection(workspace: workspace, index: index, count: workspaces.workspaces.count)
            }

            Section {
                Button("New Workspace") { workspaces.create() }
            } footer: {
                Caption("Jump shortcuts work while the notch is open. The startup command is typed into every new tab, e.g. ssh my-server.")
            }

            Section {
                ForEach(coordinator.screens, id: \.id) { screen in
                    Picker(selection: Binding(
                        get: { coordinator.workspace(forScreen: screen.id).id },
                        set: { id in
                            if let workspace = workspaces.workspace(id) {
                                coordinator.assign(workspace, toScreen: screen.id)
                            }
                        }
                    )) {
                        ForEach(workspaces.workspaces) { Text($0.name).tag($0.id) }
                    } label: {
                        Label(screen.name, systemImage: screen.hasNotch ? "laptopcomputer" : "display")
                    }
                }
            } header: {
                Text("Displays")
            } footer: {
                Caption("Several displays can share one workspace; it opens on one display at a time.")
            }
        }
    }
}

private struct WorkspaceSection: View {
    @ObservedObject var workspace: Workspace
    let index: Int
    let count: Int
    @EnvironmentObject private var workspaces: WorkspaceStore
    @EnvironmentObject private var coordinator: NotchCoordinator
    @State private var isConfirmingDelete = false
    @State private var draftName = ""
    @State private var draftCommand = ""

    var body: some View {
        Section {
            TextField("Name", text: $draftName)
                .onSubmit { workspaces.rename(workspace, to: draftName) }
                .onChange(of: workspace.name) { _, name in draftName = name }
            LabeledContent("Jump shortcut") {
                HotkeyRecorder(
                    chord: Binding(get: { workspace.hotkey }, set: { workspaces.setHotkey($0, for: workspace) }),
                    allowsClearing: true
                )
            }
            LabeledContent("Startup folder") {
                HStack(spacing: 6) {
                    Text(workspace.directory.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Home")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Button("Choose…", action: chooseFolder)
                    if workspace.directory != nil {
                        Button {
                            workspaces.setDirectory(nil, for: workspace)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Use the home folder")
                    }
                }
            }
            TextField("Startup command", text: $draftCommand, prompt: Text("None"))
                .onSubmit { workspaces.setStartupCommand(draftCommand, for: workspace) }
            HStack {
                Text(workspace.tabs.isEmpty ? "Not opened yet" : "\(workspace.tabs.count) open tab\(workspace.tabs.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    workspaces.move(workspace, by: -1)
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(index == 0)
                .help("Move up")
                Button {
                    workspaces.move(workspace, by: 1)
                } label: {
                    Image(systemName: "arrow.down")
                }
                .disabled(index == count - 1)
                .help("Move down")
                Button("Delete…", role: .destructive) { isConfirmingDelete = true }
                    .disabled(!workspaces.canDelete)
            }
        } header: {
            Text(workspace.name)
        }
        .onAppear {
            draftName = workspace.name
            draftCommand = workspace.startupCommand ?? ""
        }
        .onDisappear {
            workspaces.rename(workspace, to: draftName)
            workspaces.setStartupCommand(draftCommand, for: workspace)
        }
        .confirmationDialog("Delete “\(workspace.name)”?", isPresented: $isConfirmingDelete) {
            Button("Delete and Close Its Tabs", role: .destructive) { coordinator.delete(workspace) }
        } message: {
            Text("Displays showing it switch to another workspace.")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        if let directory = workspace.directory {
            panel.directoryURL = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workspaces.setDirectory(url.path, for: workspace)
    }
}

// MARK: - About

private struct AboutPage: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Top NotchSH")
                .font(.largeTitle.weight(.semibold))
            Text("Version \(version)")
                .foregroundStyle(.secondary)
            Text("A terminal that lives in your notch.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
