#if DEBUG
import AppKit
import Carbon.HIToolbox
import SwiftTerm
import SwiftUI

/// End-to-end scenario run with `--self-test <output-dir>` (Debug builds only).
///
/// Drives the real app: shells are spawned, keystrokes are posted to the event
/// queue (so they pass through `InputRouter` and SwiftTerm like real typing),
/// and results are read back from the terminal buffers. Writes `report.txt`
/// and screenshots to the output directory, then quits.
@MainActor
final class SelfTest {
    static var isRequested: Bool { outputDirectory != nil }

    static var outputDirectory: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--self-test"), index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    /// A throwaway config directory so test runs never touch real settings.
    static let config: ConfigDirectory = {
        let url = FileManager.default.temporaryDirectory.appending(path: "top-notchsh-selftest", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: url)
        return ConfigDirectory(url: url)
    }()

    private let model: AppModel
    private let output: URL
    private var lines: [String] = []
    private var failures = 0

    init(model: AppModel) {
        self.model = model
        output = Self.outputDirectory!
    }

    func start() {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        Task { @MainActor in
            if ProcessInfo.processInfo.arguments.contains("--memory") {
                await measureMemory()
            } else if ProcessInfo.processInfo.arguments.contains("--screenshots") {
                await captureReadmeImages()
            } else {
                await run()
            }
            log("\nRESULT: \(failures == 0 ? "PASS" : "FAIL (\(failures) failed)")")
            try? lines.joined(separator: "\n").write(to: output.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    // MARK: - Scenario

    private func run() async {
        let started = Date()
        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.localizedName ?? "?"
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
            MainActor.assumeIsolated { self?.log("  ⓘ [\(elapsed)s] \(app) became active") }
        }
        defer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        await sleep(1)
        guard let notch = model.coordinator.controllers.values.first else {
            check("a notch panel exists", false)
            return
        }
        let settings = model.settings
        let geometry = notch.geometry
        log("Screen: \(geometry.name) \(geometry.frame) notch=\(geometry.notchHeight)x\(geometry.notchWidth) menuBar=\(geometry.menuBarHeight)")

        // Closed state
        let closedSize = geometry.closedSize(for: settings.settings.sizing)
        check("closed panel hugs the notch (\(notch.panel.frame.size) == \(closedSize))", notch.panel.frame.size == closedSize)
        check("closed panel touches top of screen", notch.panel.frame.maxY == geometry.frame.maxY)
        check("closed panel is centered", abs(notch.panel.frame.midX - geometry.frame.midX) <= 0.5)
        await screenshot("01-closed")

        // Global hotkey registration (a spare chord; ⌘⏎ may belong to another app)
        let hotkey = GlobalHotkey()
        check("global hotkey registers with Carbon", hotkey.register(KeyChord([.command, .option, .control], kVK_F12)) == .registered)
        hotkey.invalidate()

        // Open
        model.perform(.toggleNotch)
        await sleep(0.12)
        await screenshot("01b-opening")
        check("opens on toggle", await until { notch.isOpen && notch.panel.isKeyWindow })
        await sleep(0.8)
        let workspace = notch.workspace
        guard let tab1 = workspace.activeTab else {
            check("first tab created", false)
            return
        }
        check("first tab is focused", await until { notch.panel.firstResponder === tab1.view })
        check("open size matches settings", notch.size == geometry.openSize(for: settings.settings.sizing))
        check("panel settled with shadow margin", notch.panel.frame.width > notch.size.width)
        checkLayout(notch, tab1, label: "default size")
        check("shell prompt appears", await until(5) { !self.text(tab1).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        await screenshot("02-open")

        // Typing
        await type("echo hello-$((40+2))\r")
        check("typed command runs", await until { self.hasLine(tab1, "hello-42") })

        // ⌘← / ⌘→
        await type("abc")
        await key(kVK_LeftArrow, .command)
        await type("echo X")
        await key(kVK_RightArrow, .command)
        await type("Y\r")
        check("⌘← jumps to line start, ⌘→ to end", await until { self.hasLine(tab1, "XabcY") }, tail(tab1))

        // ⌘⌫
        await type("garbage")
        await key(kVK_Delete, .command)
        await type("echo killed\r")
        check("⌘⌫ deletes the line", await until { self.hasLine(tab1, "killed") } && !text(tab1).contains("garbageecho"), tail(tab1))

        // ⌥← word jump (Option as Meta)
        await type("echo one two")
        await key(kVK_LeftArrow, .option)
        await type("Z\r")
        check("⌥← moves by word", await until { self.hasLine(tab1, "one Ztwo") }, tail(tab1))
        await type("echo aa bb")
        await key(kVK_LeftArrow, .option)
        await key(kVK_LeftArrow, .option)
        await key(kVK_RightArrow, .option)
        await type("Q\r")
        check("⌥→ moves by word", await until { self.hasLine(tab1, "aa Qbb") }, tail(tab1))

        // ⌘L
        await key(kVK_ANSI_L, .command)
        check("⌘L clears the screen", await until { !self.visibleText(tab1).contains("Ztwo") }, visibleText(tab1))

        // ⌘C / ⌘V
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("echo pasted-ok", forType: .string)
        await key(kVK_ANSI_V, .command)
        await type("\r")
        check("⌘V pastes", await until { self.hasLine(tab1, "pasted-ok") }, tail(tab1))
        await key(kVK_ANSI_A, .command)
        await key(kVK_ANSI_C, .command)
        check("⌘A ⌘C copies the selection", NSPasteboard.general.string(forType: .string)?.contains("pasted-ok") == true)
        tab1.view.selectNone()

        // New tab inherits cwd
        await type("cd /usr/share\r")
        await sleep(0.4)
        await key(kVK_ANSI_T, .command)
        check("⌘T opens a tab", await until { workspace.tabs.count == 2 && workspace.activeTab !== tab1 })
        let tab2 = workspace.activeTab!
        check("new tab takes focus", await until { notch.panel.firstResponder === tab2.view })
        check("new tab gets a prompt", await until(5) { !self.text(tab2).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        await type("pwd\r")
        check("new tab opens in the previous tab's directory", await until { self.hasLine(tab2, "/usr/share") }, tail(tab2))
        await screenshot("03-two-tabs")

        // Tab navigation
        await key(kVK_ANSI_1, .command)
        check("⌘1 selects the first tab", await until { workspace.activeTab === tab1 && notch.panel.firstResponder === tab1.view })
        await key(kVK_ANSI_RightBracket, [.command, .shift])
        check("⌘⇧] selects the next tab", await until { workspace.activeTab === tab2 })
        await key(kVK_ANSI_RightBracket, [.command, .shift])
        check("next tab wraps around", await until { workspace.activeTab === tab1 })
        await key(kVK_ANSI_LeftBracket, [.command, .shift])
        check("⌘⇧[ selects the previous tab", await until { workspace.activeTab === tab2 })
        check("tab 1 kept its output while hidden", hasLine(tab1, "pasted-ok"))

        // Drag to reorder: lift the first of three tabs and drop it between the others
        await key(kVK_ANSI_T, .command)
        _ = await until { workspace.tabs.count == 3 }
        let thirdTab = workspace.activeTab!
        await key(kVK_ANSI_1, .command)
        _ = await until { workspace.activeTab === tab1 }
        let before = workspace.tabs.map(\.id)
        check("three tabs to drag between", before.count == 3, "\(before.count) tabs")
        guard before.count == 3 else { return }
        let window = notch.panel
        let margin = (window.frame.width - notch.size.width) / 2
        let stripY = window.frame.height - notch.size.height + OpenNotchView.tabStripHeight / 2
        let start = CGPoint(x: margin + 60, y: stripY)
        await pressAndMove(in: window, from: start, to: CGPoint(x: start.x + 230, y: stripY))
        await sleep(0.4)
        check("order is unchanged while dragging (preview only)", workspace.tabs.map(\.id) == before)
        await screenshot("03b-mid-drag")
        await release(in: window, at: CGPoint(x: start.x + 230, y: stripY))
        check("dropping commits the previewed order", await until { workspace.tabs.map(\.id) == [before[1], before[0], before[2]] }, "order unchanged")
        check("dragged tab is active", workspace.activeTab === tab1)
        await sleep(0.3)
        await screenshot("03c-dropped")
        await pressAndMove(in: window, from: CGPoint(x: start.x + 200, y: stripY), to: CGPoint(x: start.x - 40, y: stripY))
        await release(in: window, at: CGPoint(x: start.x - 40, y: stripY))
        check("dragging it back restores the order", await until { workspace.tabs.map(\.id) == before })
        workspace.closeTab(thirdTab.id)
        await key(kVK_ANSI_2, .command)
        _ = await until { workspace.activeTab === tab2 }

        // ⌘W
        await key(kVK_ANSI_W, .command)
        check("⌘W closes the tab", await until { workspace.tabs.count == 1 && workspace.activeTab === tab1 })
        check("focus returns to the remaining tab", await until { notch.panel.firstResponder === tab1.view })

        // `exit` closes its tab
        await key(kVK_ANSI_T, .command)
        _ = await until { workspace.tabs.count == 2 }
        let tab3 = workspace.activeTab!
        _ = await until(5) { !self.text(tab3).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        await type("exit\r")
        check("exiting the shell closes its tab", await until(4) { workspace.tabs.count == 1 && workspace.activeTab === tab1 })

        // ⌘R reset
        let terminal = tab1.view.getTerminal()
        await type("printf '\\e[?1003h\\e[?1006h\\e[?1h\\e[?1049h'\r")
        check("program can enable mouse reporting", await until { terminal.mouseMode != .off && terminal.isCurrentBufferAlternate })
        await key(kVK_ANSI_R, .command)
        check("⌘R turns off mouse reporting", await until { terminal.mouseMode == .off })
        check("⌘R leaves the alternate screen", !terminal.isCurrentBufferAlternate)
        await type("echo after-reset\r")
        check("shell still works after ⌘R", await until { self.hasLine(tab1, "after-reset") }, tail(tab1))

        // ⌘R after a program like Claude Code (kitty keyboard on the main
        // screen) or tmux over a dropped SSH connection (alternate screen).
        await type("clear; seq 1 5; printf '\\e[>1u\\e[?2004h\\e[5 q'\r")
        check("program can enable the kitty keyboard", await until { !terminal.keyboardEnhancementFlags.isEmpty }, tail(tab1))
        await sleep(0.3)
        let rowBefore = terminal.buffer.y
        await key(kVK_ANSI_R, .command)
        check("⌘R turns off the kitty keyboard", await until { terminal.keyboardEnhancementFlags.isEmpty })
        await sleep(0.4)
        check("⌘R keeps the cursor below existing text", terminal.buffer.y >= rowBefore,
              "before \(rowBefore), after \(terminal.buffer.y)\n\(tail(tab1))")
        await type("sleep 30\r")
        await sleep(0.5)
        await key(kVK_ANSI_C, .control)
        await type("echo after-kitty\r")
        check("⌃C works after ⌘R", await until { self.hasLine(tab1, "after-kitty") }, tail(tab1))
        check("lines above the prompt are untouched", ["1", "2", "3", "4", "5"].allSatisfy { self.hasLine(tab1, $0) }, text(tab1))

        await type("echo before-ssh; printf '\\e[?1049h\\e[>1u\\e[?1003h\\e[?1h'; echo 'Connection closed.'\r")
        _ = await until { terminal.isCurrentBufferAlternate && !terminal.keyboardEnhancementFlags.isEmpty }
        await sleep(0.3)
        await key(kVK_ANSI_R, .command)
        check("⌘R leaves the alternate screen with the kitty keyboard off",
              await until { !terminal.isCurrentBufferAlternate && terminal.keyboardEnhancementFlags.isEmpty && terminal.mouseMode == .off })
        await type("echo after-ssh\r")
        check("shell works after a dropped connection and ⌘R", await until { self.hasLine(tab1, "after-ssh") }, tail(tab1))
        check("text before the program is untouched", hasLine(tab1, "before-ssh"), tail(tab1))
        log("  terminal after ⌘R:\n\(tail(tab1))")

        // Mouse wheel reporting
        await type("printf '\\e[?1000h\\e[?1006h'; cat -v\r")
        _ = await until { terminal.mouseMode != .off }
        await sleep(0.3)
        let reported: @MainActor () -> Bool = { self.text(tab1).contains("[<64;") || self.text(tab1).contains("[<65;") }
        postScroll(over: tab1.view, in: notch.panel)
        if await until(1.5, reported) {
            check("wheel is reported to mouse-aware programs (via InputRouter)", true)
        } else {
            log("  (scroll event did not reach the app through the window server; testing the session directly)")
            if let event = scrollEvent(over: tab1.view, in: notch.panel) {
                _ = tab1.handleScrollWheel(event)
            }
            check("wheel is reported to mouse-aware programs (direct)", await until(2, reported), tail(tab1))
        }
        await key(kVK_ANSI_C, .control)
        await key(kVK_ANSI_R, .command)
        await type("echo after-cat\r")
        check("⌃C interrupts the program", await until { self.hasLine(tab1, "after-cat") }, tail(tab1))

        // Scroller only shows while reading scrollback
        check("scroller is hidden at the live bottom", !tab1.isScrollerVisible)
        await type("seq 1 300\r")
        _ = await until { self.hasLine(tab1, "300") }
        tab1.view.scroll(toPosition: 0.2)
        check("scroller appears when scrolled back", await until { tab1.isScrollerVisible })
        await screenshot("05a-scrolled-back")
        await type("echo back\r")
        check("scroller fades once typing returns to the bottom", await until { !tab1.isScrollerVisible })

        // Font size
        let baseFont = settings.settings.terminal.fontSize
        await key(kVK_ANSI_Equal, .command)
        check("⌘= enlarges the font", await until { settings.settings.terminal.fontSize == baseFont + 1 && tab1.view.font.pointSize == baseFont + 1 })
        await key(kVK_ANSI_Minus, .command)
        await key(kVK_ANSI_Minus, .command)
        check("⌘- shrinks the font", await until { settings.settings.terminal.fontSize == baseFont - 1 })
        await key(kVK_ANSI_0, .command)
        check("⌘0 resets the font", await until { settings.settings.terminal.fontSize == TerminalSettings.defaultFontSize })

        // Size presets
        await key(kVK_ANSI_1, [.command, .shift])
        let compact = geometry.clampOpenSize(SizePreset.defaults[0].size)
        check("⌘⇧1 applies the Compact preset", await until(3) { notch.size == compact && notch.openLayoutSize == compact })
        await sleep(settings.settings.motion.resizeDuration + 0.3)
        check("panel shrinks after the preset animation", abs(notch.panel.frame.width - notch.size.width) < 60 && notch.panel.frame.height < 300)
        checkLayout(notch, tab1, label: "compact")
        await screenshot("04-compact")
        await key(kVK_ANSI_3, [.command, .shift])
        let large = geometry.clampOpenSize(SizePreset.defaults[2].size)
        check("⌘⇧3 applies the Large preset", await until(3) { notch.size == large })
        await sleep(settings.settings.motion.resizeDuration + 0.3)
        checkLayout(notch, tab1, label: "large")
        await screenshot("05-large")
        await key(kVK_ANSI_2, [.command, .shift])
        _ = await until(3) { notch.size == geometry.clampOpenSize(SizePreset.defaults[1].size) }
        await sleep(settings.settings.motion.resizeDuration + 0.3)

        // Padding
        settings.update { $0.padding.notched.bottom = 24; $0.padding.external.bottom = 24 }
        await sleep(0.4)
        checkLayout(notch, tab1, label: "bottom padding 24")
        await screenshot("06-padding-24")
        settings.update { $0.padding = PaddingSettings() }
        await sleep(0.3)

        // Workspaces
        let main = workspace
        notch.perform(.createWorkspace)
        check("new workspace is shown", await until { notch.workspace !== main && notch.workspace.tabs.count == 1 })
        let second = notch.workspace
        check("new workspace's tab takes focus", await until { notch.panel.firstResponder === second.activeTab?.view })
        await screenshot("07-second-workspace")
        await key(kVK_UpArrow, [.command, .shift])
        check("⌘⇧↑ switches workspace", await until { notch.workspace === main })
        await key(kVK_DownArrow, [.command, .shift])
        check("⌘⇧↓ switches workspace", await until { notch.workspace === second })
        await key(kVK_DownArrow, [.command, .shift])
        check("workspace switching wraps", await until { notch.workspace === main })
        check("previous workspace's tab is focused again", await until { notch.panel.firstResponder === tab1.view })
        check("previous workspace kept its scrollback", hasLine(tab1, "after-cat"))
        model.workspaces.setHotkey(KeyChord([.command, .option], kVK_ANSI_2), for: second)
        await key(kVK_ANSI_2, [.command, .option])
        check("workspace jump hotkey works", await until { notch.workspace === second })
        notch.perform(.deleteWorkspace(second.id))
        check("deleting a workspace falls back to another", await until { notch.workspace === main && self.model.workspaces.workspaces.count == 1 })
        check("deleted workspace's shells are gone", second.tabs.isEmpty)

        await newFeatureChecks(notch: notch, tab1: tab1)

        // Detach to window
        await key(kVK_ANSI_T, .command)
        _ = await until { workspace.tabs.count == 2 }
        let detached = workspace.activeTab!
        _ = await until(5) { !self.text(detached).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        await key(kVK_ANSI_D, .command)
        check("⌘D moves the tab to a window", await until { workspace.tabs.count == 1 && detached.view.window != nil && !(detached.view.window is NotchPanel) })
        check("closing focus closes the notch", await until { !notch.isOpen })
        let popout = detached.view.window
        check("pop-out terminal is focused", await until { popout?.isKeyWindow == true && popout?.firstResponder === detached.view })
        await type("echo popped\r")
        check("pop-out terminal works", await until { self.hasLine(detached, "popped") }, tail(detached))
        await screenshot("08-popout")

        await checkScreenSharing(of: popout, name: "a pop-out")
        popout?.performClose(nil)
        check("closing the pop-out window closes it", await until { popout?.isVisible == false })

        // Reopen keeps state
        await sleep(0.5)
        model.perform(.toggleNotch)
        check("reopens", await until { notch.isOpen && notch.panel.isKeyWindow })
        check("reopened notch focuses the same tab", await until { notch.panel.firstResponder === tab1.view })
        check("reopened tab kept its output", hasLine(tab1, "after-cat"))

        // Settings window closes the notch (focus loss)
        model.perform(.showSettings)
        check("settings window opens", await until { NSApp.keyWindow?.identifier == SettingsWindow.identifier },
              "active=\(NSApp.isActive) key=\(NSApp.keyWindow?.title ?? "nil") visible=\(NSApp.windows.filter(\.isVisible).map { "\(Swift.type(of: $0)):\($0.title)" })")
        check("notch closes when focus moves elsewhere", await until { !notch.isOpen })
        await sleep(0.6)
        let listener = ChordListener()
        var recorded: KeyChord?
        listener.start { recorded = $0 }
        await key(kVK_ANSI_K, [.command, .shift])
        check("shortcut recorder captures a chord after one click", await until { recorded == KeyChord([.command, .shift], kVK_ANSI_K) && !listener.isListening })
        listener.start { recorded = $0 }
        await key(kVK_Escape, [])
        check("Esc cancels recording", await until { !listener.isListening } && recorded == KeyChord([.command, .shift], kVK_ANSI_K))
        if let window = NSApp.keyWindow {
            for page in SettingsView.Page.allCases {
                window.contentView = NSHostingView(rootView: SettingsView(page: page)
                    .environmentObject(model.settings)
                    .environmentObject(model.workspaces)
                    .environmentObject(model.coordinator)
                    .environmentObject(model.input.hotkeyStatus)
                    .environmentObject(model.updates))
                await sleep(0.5)
                await screenshot("09-settings-\(page.rawValue)")
            }
        }
        NSApp.keyWindow?.performClose(nil)
        await sleep(0.4)

        // Close via toggle
        model.perform(.toggleNotch)
        _ = await until { notch.isOpen }
        await sleep(0.6)
        model.perform(.toggleNotch)
        let closeStarted = Date()
        check("closes on toggle", await until { !notch.isOpen })
        let shrank = await until(5) { notch.panel.frame.size == closedSize }
        log("  panel shrank \(String(format: "%.2f", Date().timeIntervalSince(closeStarted)))s after close")
        check("closed panel shrinks back to the notch within 1s", shrank && Date().timeIntervalSince(closeStarted) < 1, "\(notch.panel.frame.size)")
        await screenshot("10-closed-again")

        // Click to open
        let clicked = postClick(at: CGPoint(x: notch.panel.frame.midX, y: notch.panel.frame.maxY - closedSize.height / 2), in: notch.panel)
        let openedByClick = await until { notch.isOpen }
        check("clicking the closed notch opens it", clicked && openedByClick)
        model.perform(.toggleNotch)
        _ = await until { !notch.isOpen }
        await sleep(0.8)
    }

    // MARK: - README screenshots

    /// Captures windows on their own (transparent background), so nothing
    /// else on the screen ends up in the image.
    private func captureWindow(_ window: NSWindow, _ name: String, shadow: Bool = true) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x"] + (shadow ? [] : ["-o"]) + ["-l", "\(window.windowNumber)", output.appendingPathComponent("\(name).png").path]
        try? process.run()
        process.waitUntilExit()
        log("captured \(name)")
    }

    /// Captures a strip of the screen (top-left origin, in points).
    private func captureRegion(_ rect: CGRect, _ name: String) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-R", "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))", output.appendingPathComponent("\(name).png").path]
        try? process.run()
        process.waitUntilExit()
        log("captured \(name)")
    }

    /// Sets up a representative scene for the README. Run with a neutral
    /// ZDOTDIR so the shell prompt shows no personal details.
    private func captureReadmeImages() async {
        let settings = model.settings
        let demoFolder = ProcessInfo.processInfo.environment["TOPNOTCHSH_DEMO_FOLDER"] ?? NSHomeDirectory()
        settings.update {
            $0.sizing.openWidth = 760
            $0.sizing.openHeight = 400
            $0.activity.minimumCommandSeconds = 1
            $0.general.hasSeenWelcome = true
        }
        await sleep(1)
        guard let notch = model.coordinator.controllers.values.first else { return }
        model.perform(.toggleNotch)
        _ = await until { notch.isOpen && notch.panel.isKeyWindow }
        let workspace = notch.workspace
        let main = workspace.activeTab!
        _ = await until(5) { !self.text(main).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        // Background tabs: one rings the bell so its activity dot shows.
        workspace.renameTab(main.id, to: "top-notchsh")
        await key(kVK_ANSI_T, .command)
        _ = await until { workspace.tabs.count == 2 }
        let server = workspace.activeTab!
        workspace.renameTab(server.id, to: "server")
        _ = await until(5) { !self.text(server).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        await type("clear; sleep 1; printf '\\a'\r")
        await key(kVK_ANSI_T, .command)
        _ = await until { workspace.tabs.count == 3 }
        workspace.renameTab(workspace.activeTab!.id, to: "notes")
        await key(kVK_ANSI_1, .command)
        _ = await until { workspace.activeTab === main && notch.panel.firstResponder === main.view }

        // The main tab: a project listing and its history.
        await type("cd '\(demoFolder)' && clear\r")
        await sleep(0.5)
        await type("ls -lgoh\r")
        await sleep(0.4)
        await type("git status -sb\r")
        _ = await until(4) { server.activity == .bell }
        await sleep(1)
        main.view.selectNone()
        await captureWindow(notch.panel, "notch-open")

        // Closed notch showing that a command finished.
        await type("sleep 2\r")
        await sleep(0.4)
        model.perform(.toggleNotch)
        _ = await until(6) { !notch.isOpen && notch.activity == .finished }
        await sleep(1.2)
        let screen = notch.geometry.frame
        let panel = notch.panel.frame
        await captureRegion(CGRect(x: panel.midX - screen.minX - 220, y: 0, width: 440, height: 56), "notch-activity")

        // Settings and the welcome window.
        model.perform(.showSettings)
        _ = await until { NSApp.keyWindow?.identifier == SettingsWindow.identifier }
        if let window = NSApp.keyWindow {
            window.contentView = NSHostingView(rootView: SettingsView(page: .terminal)
                .environmentObject(model.settings)
                .environmentObject(model.workspaces)
                .environmentObject(model.coordinator)
                .environmentObject(model.input.hotkeyStatus)
                .environmentObject(model.updates))
            await sleep(1)
            await captureWindow(window, "settings")
            window.performClose(nil)
        }
        settings.update { $0.general.hasSeenWelcome = false }
        model.showWelcome()
        let welcome: () -> NSWindow? = { NSApp.windows.first { $0.title == "Welcome to Top NotchSH" && $0.isVisible } }
        _ = await until { welcome() != nil }
        await sleep(1)
        if let window = welcome() {
            await captureWindow(window, "welcome")
            window.performClose(nil)
        }
        await sleep(0.5)
    }

    // MARK: - Memory report

    /// The app's memory as Activity Monitor reports it (physical footprint), in MB.
    private static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return Double(info.phys_footprint) / 1_048_576
    }

    /// Resident memory of the shells (child processes), in MB.
    private static func shellMemory() -> (count: Int, megabytes: Double) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "ppid=,rss="]
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let rows = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n")
            .map { $0.split(separator: " ").compactMap { Int($0) } }
            .filter { $0.count == 2 && $0[0] == Int(getpid()) }
        return (rows.count, Double(rows.map { $0[1] }.reduce(0, +)) / 1024)
    }

    private func report(_ label: String, previous: inout Double) {
        let now = Self.footprint()
        let shells = Self.shellMemory()
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        let inUse = Double(stats.size_in_use) / 1_048_576
        log(String(format: "%-46@ app %6.1f MB  (%+6.1f)  heap in use %6.1f MB   shells: %2d using %5.1f MB",
                   label as NSString, now, now - previous, inUse, shells.count - 1, shells.megabytes))
        previous = now
    }

    private func settle() async {
        await sleep(1.5)
    }

    private func measureMemory() async {
        let settings = model.settings
        var last = Self.footprint()
        log("CharData: \(MemoryLayout<CharData>.stride) bytes per cell")
        await settle()
        report("launched, notch closed, no shells", previous: &last)

        guard let notch = model.coordinator.controllers.values.first else { return }
        model.perform(.toggleNotch)
        _ = await until { notch.isOpen }
        let workspace = notch.workspace
        let tab = workspace.activeTab!
        _ = await until(5) { !self.text(tab).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        await settle()
        let terminal = tab.view.getTerminal()
        log("grid: \(terminal.cols) columns x \(terminal.rows) rows, scrollback limit \(settings.settings.terminal.scrollbackLines)")
        report("1 tab open", previous: &last)

        for _ in 0..<9 {
            workspace.newTab()
        }
        _ = await until(10) { workspace.tabs.allSatisfy { !self.text($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
        await settle()
        report("10 tabs open (empty scrollback)", previous: &last)

        workspace.selectTab(tab.id)
        _ = await until { notch.panel.firstResponder === tab.view }
        let filler = "seq -f 'line %06g ................................' 1"
        await type("\(filler) 10000\r")
        _ = await until(20) { self.hasLine(tab, "line 010000 ................................") }
        await settle()
        report("1 tab: 10,000 lines through 5,000 scrollback", previous: &last)

        settings.update { $0.terminal.scrollbackLines = 50_000 }
        await type("\(filler) 60000\r")
        _ = await until(60) { self.hasLine(tab, "line 060000 ................................") }
        await settle()
        report("same tab: scrollback raised to 50,000, filled", previous: &last)

        settings.update { $0.terminal.scrollbackLines = 1_000 }
        await settle()
        report("scrollback lowered to 1,000", previous: &last)
        await type("\(filler) 10000\r")
        _ = await until(20) { self.hasLine(tab, "line 010000 ................................") }
        await settle()
        report("printed 10,000 more lines (1,000 kept)", previous: &last)

        // Weak references reveal whether closed tabs are really freed.
        var probes = workspace.tabs.filter { $0 !== tab }.map { WeakSession(session: $0) }
        let closedCount = probes.count
        for probe in probes {
            if let id = probe.session?.id { workspace.closeTab(id) }
        }
        await settle()
        report("closed the 9 other tabs", previous: &last)
        probes.removeAll { $0.session == nil }
        log("closed tabs still in memory: \(probes.count) of \(closedCount)")
        settings.update { $0.terminal.scrollbackLines = TerminalSettings().scrollbackLines }
    }

    private struct WeakSession {
        weak var session: TerminalSession?
    }

    // MARK: - Feature checks

    private func newFeatureChecks(notch: NotchController, tab1: TerminalSession) async {
        let settings = model.settings
        let workspace = notch.workspace
        _ = await until { notch.panel.firstResponder === tab1.view }

        // ⌘F find bar, searching a marker that has scrolled into history
        await type("echo findme-$((6*7))\r")
        _ = await until { self.hasLine(tab1, "findme-42") }
        await type("seq 1 60\r")
        _ = await until { self.hasLine(tab1, "60") }
        await key(kVK_ANSI_F, .command)
        let findField: () -> NSSearchField? = {
            Self.descendants(of: tab1.view).compactMap { $0 as? NSSearchField }.first { !$0.isHiddenOrHasHiddenAncestor }
        }
        check("⌘F shows the find bar", await until { findField() != nil })
        await screenshot("11-find")
        check("find field takes keyboard focus", await until { (hostWindow(of: tab1)?.firstResponder as? NSText)?.delegate === findField() })
        await key(kVK_ANSI_A, .command)
        check("⌘A works inside the find field", await until {
            ((self.hostWindow(of: tab1)?.firstResponder as? NSTextView)?.selectedRange().length ?? 0) == (findField()?.stringValue.count ?? -1)
        })
        await type("findme-42")
        await sleep(0.4)
        check("typing in the find bar finds text in the scrollback", await until { tab1.view.getSelection() == "findme-42" },
              "selection=\(tab1.view.getSelection() ?? "nil")")
        await key(kVK_Escape, [])
        _ = await until { findField() == nil }
        tab1.view.selectNone()
        tab1.focus()

        // Double-click to rename the tab
        let window = notch.panel
        let margin = (window.frame.width - notch.size.width) / 2
        let tabPoint = CGPoint(x: margin + 60, y: window.frame.height - notch.size.height + OpenNotchView.tabStripHeight / 2)
        postClick(at: tabPoint, in: window, count: 1)
        postClick(at: tabPoint, in: window, count: 2)
        check("double-clicking a tab starts renaming", await until { window.firstResponder is NSTextView })
        await type("build\r")
        check("renamed tab shows its new name", await until { tab1.displayTitle == "build" }, tab1.displayTitle)
        check("renaming returns focus to the terminal", await until { window.firstResponder === tab1.view })
        await screenshot("12-renamed")

        // Paths are escaped when inserted
        await type("echo ")
        tab1.insert(paths: ["/tmp/a b(1)"])
        await type("\r")
        check("dropped paths are shell-escaped", await until { self.hasLine(tab1, "/tmp/a b(1)") }, tail(tab1))

        // A long command finishing while the notch is closed
        settings.update { $0.activity.minimumCommandSeconds = 1 }
        await type("sleep 2\r")
        await sleep(0.6)
        model.perform(.toggleNotch)
        _ = await until { !notch.isOpen }
        let baseWidth = notch.geometry.closedSize(for: settings.settings.sizing).width
        check("finished command lights up the closed notch", await until(5) { workspace.activity == .finished && notch.activity == .finished })
        check("closed notch widens for the indicator", await until(2) { notch.size.width == baseWidth + NotchController.indicatorWidth * 2 }, "\(notch.size.width)")
        await sleep(0.6)
        check("panel fits the wider closed notch", notch.panel.frame.width == baseWidth + NotchController.indicatorWidth * 2, "\(notch.panel.frame.width)")
        await screenshot("13-activity-finished")
        model.perform(.toggleNotch)
        check("opening the notch clears the activity", await until { notch.isOpen && workspace.activity == nil })

        // A background tab ringing the bell
        await type("sleep 1; printf '\\a'\r")
        await key(kVK_ANSI_T, .command)
        _ = await until { workspace.tabs.count == 2 }
        let other = workspace.activeTab!
        check("bell in a background tab marks it", await until(4) { tab1.activity == .bell }, "\(String(describing: tab1.activity))")
        await screenshot("14-tab-bell")
        await key(kVK_ANSI_1, .command)
        check("selecting the tab clears its mark", await until { tab1.activity == nil && workspace.activity == nil })

        // ⌘⇧T reopens a closed tab in its folder
        await key(kVK_ANSI_2, .command)
        _ = await until { workspace.activeTab === other }
        _ = await until(5) { !self.text(other).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        await type("cd /tmp\r")
        await sleep(0.4)
        await key(kVK_ANSI_W, .command)
        _ = await until { workspace.tabs.count == 1 }
        await key(kVK_ANSI_T, [.command, .shift])
        check("⌘⇧T reopens the closed tab", await until { workspace.tabs.count == 2 && workspace.activeTab !== tab1 })
        if let reopened = workspace.activeTab, reopened !== tab1 {
            _ = await until(5) { !self.text(reopened).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            await type("pwd\r")
            check("reopened tab is back in its folder", await until { self.hasLine(reopened, "/private/tmp") || self.hasLine(reopened, "/tmp") }, tail(reopened))
            workspace.closeTab(reopened.id)
        }
        _ = await until { workspace.activeTab === tab1 }

        // Pinning keeps the notch open when focus moves away
        await key(kVK_ANSI_P, [.command, .shift])
        check("⌘⇧P pins the notch", await until { notch.isPinned })
        await screenshot("15-pinned")
        model.perform(.showSettings)
        _ = await until { NSApp.keyWindow?.identifier == SettingsWindow.identifier }
        await sleep(0.5)
        check("pinned notch stays open when focus moves", notch.isOpen)
        model.perform(.toggleNotch)
        check("⌘⏎ focuses a pinned notch instead of closing it", await until { notch.isKey && notch.isOpen })
        NSApp.windows.first { $0.identifier == SettingsWindow.identifier }?.performClose(nil)
        notch.focus()
        await key(kVK_ANSI_P, [.command, .shift])
        check("⌘⇧P unpins", await until { !notch.isPinned })

        // Hide from screen sharing
        await checkScreenSharing(of: notch.panel, name: "the notch")
        await screenshot("16-shared-again")

        // Translucent background
        settings.update { $0.appearance.backgroundOpacity = 0.6 }
        await sleep(0.4)
        check("terminal background goes clear when translucent", tab1.view.nativeBackgroundColor.alphaComponent == 0)
        await screenshot("17-translucent")
        settings.update { $0.appearance.backgroundOpacity = 1 }
        await sleep(0.2)
        check("terminal background is opaque again", tab1.view.nativeBackgroundColor.alphaComponent == 1)

        // A workspace with its own folder and startup command
        let servers = model.workspaces.create(named: "Servers")
        model.workspaces.setDirectory("/usr", for: servers)
        model.workspaces.setStartupCommand("echo started-ok; pwd", for: servers)
        notch.perform(.selectWorkspace(servers.id))
        check("workspace startup command runs in its folder", await until(5) {
            servers.activeTab.map { self.hasLine($0, "started-ok") && self.hasLine($0, "/usr") } ?? false
        }, servers.activeTab.map(tail) ?? "no tab")
        notch.perform(.deleteWorkspace(servers.id))
        _ = await until { notch.workspace === workspace }

        // Tabs are saved with their folders and names
        model.workspaces.persist()
        let reloaded = WorkspaceStore(file: Self.config.workspaces) { [settings] directory, _ in
            TerminalSession(settings: settings, directory: directory)
        }
        let records = reloaded.workspace(workspace.id)?.tabRecords ?? []
        check("open tabs are saved for next launch", records.count == workspace.tabs.count && records.first?.name == "build", "\(records)")
        check("saved tabs remember their folders", records.allSatisfy { $0.directory != nil })
        workspace.renameTab(tab1.id, to: nil)
        settings.update { $0.activity.minimumCommandSeconds = ActivitySettings().minimumCommandSeconds }

        // Global shortcut conflicts are detected
        let spare = KeyChord([.command, .option, .control], kVK_F12)
        let holder = GlobalHotkey()
        let contender = GlobalHotkey()
        check("an unused shortcut registers", holder.register(spare) == .registered)
        check("a shortcut held by someone else is reported", contender.register(spare) == .takenByAnotherApp)
        holder.invalidate()
        contender.invalidate()
        check("the new default ⌃` is free on this Mac", !SystemShortcuts.isReserved(HotkeyAction.toggleNotch.defaultChord))
        log("  ⌘` (cycle windows) reported as a macOS shortcut: \(SystemShortcuts.isReserved(KeyChord(.command, kVK_ANSI_Grave)))")

        // Only ordinary links open
        check("web, mail and file links are allowed", ["http", "https", "mailto", "file"].allSatisfy(TerminalSession.openableLinkSchemes.contains))
        check("other URL schemes are refused", !TerminalSession.openableLinkSchemes.contains("x-apple-systempreferences"))

        // Welcome window
        settings.update { $0.general.hasSeenWelcome = false }
        model.showWelcome()
        let welcome: () -> NSWindow? = { NSApp.windows.first { $0.title == "Welcome to Top NotchSH" && $0.isVisible } }
        check("welcome window appears", await until { welcome() != nil })
        await sleep(0.6)
        await screenshot("18-welcome")
        welcome()?.performClose(nil)
        check("closing the welcome window marks it seen", await until { settings.settings.general.hasSeenWelcome })
        await sleep(0.4)
        // The welcome window took focus, which closes the notch; reopen it.
        if !notch.isOpen {
            model.perform(.toggleNotch)
        }
        notch.focus()
        _ = await until { notch.isOpen && notch.panel.firstResponder === tab1.view }
    }

    private func hostWindow(of session: TerminalSession) -> NSWindow? {
        session.view.window
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    // MARK: - Checks

    /// The terminal must sit fully between the header and the tab strip,
    /// inside the visible panel, with its grid fitting its frame.
    private func checkLayout(_ notch: NotchController, _ session: TerminalSession, label: String) {
        let view = session.view
        guard let window = view.window else {
            check("[\(label)] terminal is in a window", false)
            return
        }
        let frame = view.convert(view.bounds, to: nil)
        let windowHeight = window.frame.height
        let panelBottom = windowHeight - notch.size.height
        let insets = model.settings.settings.padding.insets(hasNotch: notch.geometry.hasNotch)
        let headerBottom = windowHeight - notch.geometry.headerHeight
        let tabStripTop = panelBottom + OpenNotchView.tabStripHeight

        check("[\(label)] terminal starts below the header/notch", frame.maxY <= headerBottom - insets.top + 0.5, "\(frame.maxY) vs \(headerBottom)")
        check("[\(label)] terminal ends above the tab strip with bottom padding", frame.minY >= tabStripTop + insets.bottom - 0.5, "\(frame.minY) vs \(tabStripTop + insets.bottom)")
        let terminal = view.getTerminal()
        let cellHeight = frame.height / CGFloat(max(terminal.rows, 1))
        let lineHeight = ceil(view.font.ascender - view.font.descender + view.font.leading)
        check("[\(label)] every row fits (\(terminal.rows) rows, cell \(String(format: "%.1f", cellHeight)) ≥ line \(lineHeight))", cellHeight + 0.5 >= lineHeight)
        log("  [\(label)] terminal frame \(frame.integral), grid \(terminal.cols)x\(terminal.rows), panel \(notch.size)")
    }

    private func check(_ name: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
        if !passed {
            failures += 1
        }
        log("\(passed ? "✅" : "❌") \(name)")
        if !passed {
            let detail = detail()
            if !detail.isEmpty {
                log("    ↳ \(detail.replacingOccurrences(of: "\n", with: "\n      "))")
            }
        }
    }

    private func log(_ line: String) {
        lines.append(line)
        // Unbuffered, so the log survives a crash.
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    // MARK: - Terminal text

    private func text(_ session: TerminalSession) -> String {
        String(decoding: session.view.getTerminal().getBufferAsData(), as: UTF8.self)
    }

    private func visibleText(_ session: TerminalSession) -> String {
        let terminal = session.view.getTerminal()
        let all = text(session).components(separatedBy: "\n")
        let dropTrailing = all.count > 0 && all.last == "" ? 1 : 0
        return all.dropLast(dropTrailing).suffix(terminal.rows).joined(separator: "\n")
    }

    private func hasLine(_ session: TerminalSession, _ line: String) -> Bool {
        text(session).components(separatedBy: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == line }
    }

    private func tail(_ session: TerminalSession) -> String {
        text(session).components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(6).joined(separator: "\n")
    }

    // MARK: - Input

    private func type(_ string: String) async {
        for character in string {
            let text = String(character)
            let keyCode = text == "\r" ? kVK_Return : 0
            postKey(keyCode: keyCode, characters: text, ignoringModifiers: text, modifiers: [])
        }
        await sleep(0.15)
    }

    private func key(_ keyCode: Int, _ modifiers: NSEvent.ModifierFlags) async {
        let base = Self.baseCharacter(for: keyCode)
        var characters = base
        if modifiers.contains(.control), let scalar = base.unicodeScalars.first, scalar.isASCII, scalar.properties.isAlphabetic {
            characters = String(UnicodeScalar(UInt8(scalar.value & 0x1F)))
        }
        var flags = modifiers
        if [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow].contains(keyCode) {
            flags.formUnion([.function, .numericPad])
        }
        postKey(keyCode: keyCode, characters: characters, ignoringModifiers: base, modifiers: flags)
        await sleep(0.25)
    }

    private func postKey(keyCode: Int, characters: String, ignoringModifiers: String, modifiers: NSEvent.ModifierFlags) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: NSApp.keyWindow?.windowNumber ?? 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: ignoringModifiers,
            isARepeat: false,
            keyCode: UInt16(keyCode)
        ) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    private static func baseCharacter(for keyCode: Int) -> String {
        let function: [Int: Int] = [
            kVK_LeftArrow: NSLeftArrowFunctionKey, kVK_RightArrow: NSRightArrowFunctionKey,
            kVK_UpArrow: NSUpArrowFunctionKey, kVK_DownArrow: NSDownArrowFunctionKey,
        ]
        if let scalar = function[keyCode] {
            return String(UnicodeScalar(UInt16(scalar))!)
        }
        let plain: [Int: String] = [
            kVK_Delete: "\u{7f}", kVK_Return: "\r", kVK_ANSI_A: "a", kVK_ANSI_C: "c", kVK_ANSI_D: "d",
            kVK_ANSI_L: "l", kVK_ANSI_R: "r", kVK_ANSI_T: "t", kVK_ANSI_V: "v", kVK_ANSI_W: "w",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_K: "k", kVK_ANSI_F: "f", kVK_ANSI_P: "p", kVK_Escape: "\u{1b}", kVK_ANSI_Equal: "=", kVK_ANSI_Minus: "-", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        ]
        return plain[keyCode] ?? ""
    }

    // MARK: - Mouse

    private func scrollEvent(over view: NSView, in window: NSWindow) -> NSEvent? {
        let local = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let screenPoint = window.convertPoint(toScreen: view.convert(local, to: nil))
        guard let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0) else { return nil }
        cgEvent.location = CGPoint(x: screenPoint.x, y: NSScreen.screens[0].frame.maxY - screenPoint.y)
        cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        return NSEvent(cgEvent: cgEvent)
    }

    /// Delivers a wheel event through the window server so it arrives like a
    /// real one and `InputRouter` hit-tests it.
    private func postScroll(over view: NSView, in window: NSWindow) {
        scrollEvent(over: view, in: window)?.cgEvent?.postToPid(getpid())
    }

    private func postMouse(_ type: NSEvent.EventType, at location: CGPoint, in window: NSWindow) {
        guard let event = NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    /// Presses at `start` and drags to `end` in window coordinates, without releasing.
    private func pressAndMove(in window: NSWindow, from start: CGPoint, to end: CGPoint, steps: Int = 24) async {
        postMouse(.leftMouseDown, at: start, in: window)
        await sleep(0.05)
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            postMouse(.leftMouseDragged, at: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t), in: window)
            await sleep(0.02)
        }
    }

    private func release(in window: NSWindow, at location: CGPoint) async {
        postMouse(.leftMouseUp, at: location, in: window)
        await sleep(0.5)
    }

    /// A click at a window location, with `count` for double-clicks.
    private func postClick(at location: CGPoint, in window: NSWindow, count: Int) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1
            ) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    private func postClick(at screenPoint: CGPoint, in window: NSWindow) -> Bool {
        let location = window.convertPoint(fromScreen: screenPoint)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ) else { return false }
            NSApp.postEvent(event, atStart: false)
        }
        return true
    }

    // MARK: - Timing & capture

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func until(_ timeout: Double = 2, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            await sleep(0.05)
        }
        return condition()
    }

    /// Turns "Hide from Screen Sharing" on and off and checks the window
    /// really disappears from screen captures and comes back. Without
    /// screen-recording permission AppKit keeps reporting a window as hidden
    /// after it is shared again, so only a real capture can tell.
    private func checkScreenSharing(of window: NSWindow?, name: String) async {
        guard let window else { return check("\(name) can be hidden from screen sharing", false) }
        model.settings.update { $0.general.hideFromScreenSharing = true }
        check("hiding from screen sharing applies to \(name)", await until { window.sharingType == NSWindow.SharingType.none })
        guard CGPreflightScreenCaptureAccess() else {
            model.settings.update { $0.general.hideFromScreenSharing = false }
            return log("  (no screen-recording permission: skipped capture checks for \(name))")
        }
        await sleep(0.3)
        check("\(name) is missing from screen captures while hidden", !capture(window))
        model.settings.update { $0.general.hideFromScreenSharing = false }
        await sleep(0.3)
        check("\(name) shows in screen captures again", capture(window))
    }

    private func capture(_ window: NSWindow) -> Bool {
        let file = output.appendingPathComponent("sharing-capture.png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        defer { try? FileManager.default.removeItem(at: file) }
        return process.terminationStatus == 0 && FileManager.default.fileExists(atPath: file.path)
    }

    private func screenshot(_ name: String) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", output.appendingPathComponent("\(name).png").path]
        try? process.run()
        process.waitUntilExit()
    }
}
#endif
