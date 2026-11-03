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

    /// A throwaway defaults domain so test runs never touch real settings.
    static let defaults: UserDefaults = {
        let defaults = UserDefaults(suiteName: "com.topnotchsh.selftest")!
        defaults.removePersistentDomain(forName: "com.topnotchsh.selftest")
        return defaults
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
            await run()
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
        check("global hotkey registers with Carbon", hotkey.register(KeyChord([.command, .option, .control], kVK_F12)))
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
        check("⌘R restores normal cursor keys", !terminal.applicationCursor)
        await type("echo after-reset\r")
        check("shell still works after ⌘R", await until { self.hasLine(tab1, "after-reset") }, tail(tab1))

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
        check("settings window opens", await until { NSApp.keyWindow?.title == "Top NotchSH Settings" })
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
                    .environmentObject(model.coordinator))
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
            kVK_ANSI_K: "k", kVK_Escape: "\u{1b}", kVK_ANSI_Equal: "=", kVK_ANSI_Minus: "-", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
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

    private func screenshot(_ name: String) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", output.appendingPathComponent("\(name).png").path]
        try? process.run()
        process.waitUntilExit()
    }
}
#endif
