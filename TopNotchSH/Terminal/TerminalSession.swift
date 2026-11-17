import AppKit
import Combine
import Darwin
import SwiftTerm

/// A SwiftTerm view that knows its owning session, so input routing can map
/// the first responder back to a session. Files dropped on it are typed in as
/// shell-escaped paths.
final class SessionTerminalView: TerminalView {
    weak var session: TerminalSession?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.fileURLs(in: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.fileURLs(in: sender)
        guard let session, !urls.isEmpty else { return false }
        session.insert(paths: urls.map(\.path))
        window?.makeFirstResponder(self)
        return true
    }

    private static func fileURLs(in info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}

/// Why a tab wants attention. Ordered by importance.
enum SessionActivity: Int, Comparable {
    case output
    case finished
    case bell

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One shell process and the terminal view that renders it.
@MainActor
final class TerminalSession: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    let view: SessionTerminalView

    /// The title the shell sets (OSC 0/2), or the shell's name.
    @Published private(set) var title: String
    /// A name the user gave the tab; overrides `title` when set.
    @Published var customName: String?
    /// Set while the tab is out of sight and something happened in it.
    @Published private(set) var activity: SessionActivity?

    var displayTitle: String { customName ?? title }

    /// When the user last typed into this terminal.
    private(set) var lastInputAt = Date.distantPast

    /// Whether a command, rather than the shell's prompt, is in the foreground.
    var isRunningCommand: Bool {
        guard let process, process.childfd >= 0, process.shellPid > 0 else { return false }
        let foreground = tcgetpgrp(process.childfd)
        return foreground > 0 && foreground != process.shellPid
    }

    /// Called once the shell process exits.
    var onExit: (() -> Void)?

    private let settings: SettingsStore
    private let shellPath: String
    private let launchDirectory: String
    private var process: LocalProcess?
    private var appliedSettings: TerminalSettings?
    private var appliedBackgroundOpacity: Double?
    private var scrollFollow = ScrollFollow()
    private var isRestoringScroll = false
    private var commandStartedAt: Date?
    private var lastForegroundCheck = Date.distantPast
    private var subscriptions = Set<AnyCancellable>()

    init(settings: SettingsStore, directory: String?) {
        let configuration = settings.settings.terminal
        self.settings = settings
        shellPath = Shell.resolve(configuredPath: configuration.shellPath)
        launchDirectory = directory.flatMap(Self.existingDirectory) ?? NSHomeDirectory()
        title = Shell.displayName(of: shellPath)
        view = SessionTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        super.init()

        view.session = self
        view.terminalDelegate = self
        view.registerForDraggedTypes([.fileURL])
        installClipboardHandler()
        updateScrollerVisibility(animated: false)
        settings.publisher(\.terminal)
            .sink { [weak self] in self?.apply($0) }
            .store(in: &subscriptions)
        settings.publisher(\.appearance.backgroundOpacity)
            .sink { [weak self] in self?.applyBackground(opacity: $0) }
            .store(in: &subscriptions)
    }

    // MARK: - Lifecycle

    /// Launches the login shell, optionally typing `command` as its first input.
    func start(running command: String? = nil) {
        guard process == nil else { return }

        let process = LocalProcess(delegate: self)
        process.startProcess(
            executable: shellPath,
            args: ["-l"],
            environment: Shell.environment(),
            execName: "-" + Shell.displayName(of: shellPath),
            currentDirectory: launchDirectory
        )
        self.process = process

        if let command = command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty {
            // The shell reads it as type-ahead once its prompt is ready.
            process.send(data: Array((command + "\r").utf8)[...])
        }
    }

    func terminate() {
        onExit = nil
        guard let process else { return }
        let pid = process.shellPid
        process.terminate()
        self.process = nil
        if pid > 0 {
            Self.hangUp(pid)
        }
    }

    /// SwiftTerm only sends SIGTERM, which interactive shells ignore, so a
    /// closed tab would keep its shell (and this session) alive. Hang up the
    /// way a real terminal does, escalate if the shell lingers, and reap it.
    private nonisolated static func hangUp(_ pid: pid_t) {
        kill(pid, SIGHUP)
        DispatchQueue.global(qos: .utility).async {
            for _ in 0..<20 {
                if waitpid(pid, nil, WNOHANG) != 0 || kill(pid, 0) != 0 {
                    return
                }
                usleep(100_000)
            }
            kill(pid, SIGKILL)
            waitpid(pid, nil, 0)
        }
    }

    func focus() {
        view.window?.makeFirstResponder(view)
    }

    /// Types shell-escaped paths at the prompt, separated by spaces.
    func insert(paths: [String]) {
        let text = paths.map(ShellEscaping.escape).joined(separator: " ") + " "
        view.send(data: Array(text.utf8)[...])
    }

    /// Shows SwiftTerm's find bar, or jumps between matches.
    func find(_ direction: FindDirection) {
        let action: NSFindPanelAction = switch direction {
        case .show: .showFindPanel
        case .next: .next
        case .previous: .previous
        }
        let item = NSMenuItem()
        item.tag = Int(action.rawValue)
        view.performFindPanelAction(item)
    }

    // MARK: - Activity

    /// True while the terminal is in a visible window the user can see.
    var isOnScreen: Bool {
        guard let window = view.window, window.isVisible else { return false }
        return (window as? NotchPanel)?.isOpen ?? true
    }

    func markSeen() {
        if activity != nil {
            activity = nil
        }
    }

    private func noteActivity(_ kind: SessionActivity) {
        guard !isOnScreen else { return }
        if activity.map({ $0 < kind }) ?? true {
            activity = kind
        }
    }

    /// Detects commands finishing by watching the terminal's foreground
    /// process group return to the shell. Throttled; called on I/O.
    private func checkForegroundProcess(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastForegroundCheck) > 0.25 else { return }
        lastForegroundCheck = now
        guard let process, process.childfd >= 0, process.shellPid > 0 else { return }

        let foreground = tcgetpgrp(process.childfd)
        guard foreground > 0 else { return }
        if foreground != process.shellPid {
            if commandStartedAt == nil {
                commandStartedAt = now
            }
        } else if let started = commandStartedAt {
            commandStartedAt = nil
            let activitySettings = settings.settings.activity
            if activitySettings.finishedCommands, now.timeIntervalSince(started) >= activitySettings.minimumCommandSeconds {
                noteActivity(.finished)
            }
        }
    }

    /// The shell's working directory, used so new tabs open where you are.
    var currentDirectory: String? {
        if let pid = process?.shellPid, pid > 0, let directory = Self.workingDirectory(of: pid) {
            return directory
        }
        return view.getTerminal().hostCurrentDirectory.flatMap { URL(string: $0)?.path }
    }

    // MARK: - Commands

    /// Puts the terminal back the way the shell expects it, after a program
    /// exits without cleaning up (for example when an SSH connection drops):
    /// keyboard and mouse modes, bracketed paste, cursor keys, the alternate
    /// screen, scroll region, colours and cursor style. If the shell is at its
    /// prompt, it is asked for a fresh one, just like pressing ⌃C.
    func resetInputModes() {
        resetDisplayState()
        view.selectNone()
        scrollFollow.reset()
        view.scroll(toPosition: 1)
        updateScrollerVisibility()

        if let process, process.shellPid > 0, !isRunningCommand {
            kill(process.shellPid, SIGINT)
        }
    }

    /// Resets the terminal's own state without touching the shell.
    private func resetDisplayState() {
        let terminal = view.getTerminal()
        view.feed(byteArray: TerminalModes.resetSequence(inAlternateScreen: terminal.isCurrentBufferAlternate)[...])
        terminal.softReset()
        let terminalSettings = appliedSettings ?? settings.settings.terminal
        terminal.setCursorStyle(CursorStyle(terminalSettings.cursorShape, blinks: terminalSettings.cursorBlinks))
        // Start on a clean line, so the next prompt doesn't land in old text.
        if terminal.buffer.x > 0 {
            view.feed(text: "\r\n")
        }
    }

    /// The scroller only appears while the user is reading scrollback; at the
    /// live bottom it fades away instead of sitting beside the text.
    private func updateScrollerVisibility(animated: Bool = true) {
        guard let scroller = view.subviews.lazy.compactMap({ $0 as? NSScroller }).first else { return }
        let alpha: CGFloat = scrollFollow.followsOutput ? 0 : 1
        guard scroller.alphaValue != alpha else { return }
        guard animated else {
            scroller.alphaValue = alpha
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = alpha > 0 ? 0.12 : 0.45
            scroller.animator().alphaValue = alpha
        }
    }

    var isScrollerVisible: Bool {
        (view.subviews.lazy.compactMap { $0 as? NSScroller }.first?.alphaValue ?? 0) > 0
    }

    func perform(_ action: TerminalKeyAction) {
        switch action {
        case .send(let bytes):
            view.send(data: bytes[...])
        case .copy:
            guard let text = view.getSelection(), !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .paste:
            view.paste(self)
        case .selectAll:
            view.selectAll(nil)
        }
    }

    /// Handles ⌘-editing shortcuts. Returns `true` if the event was consumed.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let action = TerminalKeyMap.action(
            modifiers: event.modifierFlags,
            keyCode: event.keyCode,
            applicationCursor: view.getTerminal().applicationCursor,
            optionAsMeta: view.optionAsMetaKey
        ) else {
            return false
        }
        perform(action)
        return true
    }

    /// Forwards wheel events to programs that requested mouse reporting, and
    /// turns the wheel into arrow keys on the alternate screen (less, man, …).
    /// Returns `true` if the event was consumed.
    func handleScrollWheel(_ event: NSEvent) -> Bool {
        let terminal = view.getTerminal()
        guard event.deltaY != 0 else { return false }

        let ticks = MouseWheel.ticks(for: event.deltaY)
        let scrollingUp = event.deltaY > 0

        if view.allowMouseReporting, terminal.mouseMode != .off {
            let point = view.convert(event.locationInWindow, from: nil)
            let dims = terminal.getDims()
            let cell = MouseWheel.cell(at: point, in: view.bounds, cols: dims.cols, rows: dims.rows)
            let flags = terminal.encodeButton(
                button: scrollingUp ? 4 : 5,
                release: false,
                shift: event.modifierFlags.contains(.shift),
                meta: event.modifierFlags.contains(.option),
                control: event.modifierFlags.contains(.control)
            )
            for _ in 0..<ticks {
                terminal.sendEvent(buttonFlags: flags, x: cell.column, y: cell.row, pixelX: cell.pixelX, pixelY: cell.pixelY)
            }
            return true
        }

        if terminal.isCurrentBufferAlternate {
            let arrow = scrollingUp
                ? (terminal.applicationCursor ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal)
                : (terminal.applicationCursor ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal)
            for _ in 0..<ticks {
                view.send(data: arrow[...])
            }
            return true
        }

        return false
    }

    // MARK: - Settings

    private func apply(_ settings: TerminalSettings) {
        let previous = appliedSettings
        appliedSettings = settings
        let terminal = view.getTerminal()

        if previous?.fontName != settings.fontName || previous?.fontSize != settings.fontSize {
            view.font = TerminalFont.make(name: settings.fontName, size: settings.fontSize)
        }
        if previous?.theme != settings.theme {
            let palette = settings.theme.palette
            view.nativeForegroundColor = palette.foregroundColor
            view.nativeBackgroundColor = palette.backgroundColor
            view.installColors(palette.ansiColors)
        }
        if previous?.cursorShape != settings.cursorShape || previous?.cursorBlinks != settings.cursorBlinks {
            terminal.setCursorStyle(CursorStyle(settings.cursorShape, blinks: settings.cursorBlinks))
        }
        if previous?.scrollbackLines != settings.scrollbackLines {
            terminal.changeHistorySize(max(0, settings.scrollbackLines))
        }
        view.optionAsMetaKey = settings.optionAsMeta
        if previous?.theme != settings.theme, let opacity = appliedBackgroundOpacity {
            applyBackground(opacity: opacity)
        }
    }

    /// When translucent, the terminal draws no background of its own and the
    /// window's (blurred) background shows through; text stays opaque.
    private func applyBackground(opacity: Double) {
        appliedBackgroundOpacity = opacity
        let background = (appliedSettings?.theme ?? settings.settings.terminal.theme).palette.backgroundColor
        view.nativeBackgroundColor = opacity < 1 ? background.withAlphaComponent(0) : background
        view.layer?.isOpaque = opacity >= 1
    }

    // MARK: - Helpers

    private func installClipboardHandler() {
        // OSC 52: lets programs (tmux, nvim over SSH) set the clipboard.
        let maxPayload = 1_048_576
        view.getTerminal().registerOscHandler(code: 52) { data in
            guard data.count >= 2,
                  data[data.startIndex + 1] == UInt8(ascii: ";"),
                  let content = Data(base64Encoded: Data(data.dropFirst(2))),
                  content.count <= maxPayload,
                  let text = String(data: content, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    private static func existingDirectory(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) && isDirectory.boolValue ? expanded : nil
    }

    private static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }
}

// MARK: - LocalProcessDelegate

extension TerminalSession: LocalProcessDelegate {
    nonisolated func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        Task { @MainActor in
            self.process = nil
            self.resetDisplayState()
            self.onExit?()
        }
    }

    /// SwiftTerm delivers data on the main queue (the default for `LocalProcess`).
    nonisolated func dataReceived(slice: ArraySlice<UInt8>) {
        MainActor.assumeIsolated {
            checkForegroundProcess()
            if settings.settings.activity.output {
                noteActivity(.output)
            }
            guard let anchor = scrollFollow.restorePosition(canScroll: view.canScroll) else {
                view.feed(byteArray: slice)
                return
            }
            // The user is reading scrollback: keep their viewport still.
            isRestoringScroll = true
            view.feed(byteArray: slice)
            view.scroll(toPosition: anchor)
            isRestoringScroll = false
        }
    }

    nonisolated func getWindowSize() -> winsize {
        winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
    }
}

// MARK: - TerminalViewDelegate

extension TerminalSession: TerminalViewDelegate {
    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        MainActor.assumeIsolated {
            lastInputAt = Date()
            if scrollFollow.userDidType() {
                view.scroll(toPosition: 1)
                updateScrollerVisibility()
            }
            process?.send(data: data)
            if data.contains(0x0D) {
                // A command may have just started; look once the shell has forked.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.checkForegroundProcess(force: true)
                }
            }
        }
    }

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated {
            guard newCols > 0, newRows > 0, let fd = process?.childfd, fd >= 0 else { return }
            var size = winsize(ws_row: UInt16(newRows), ws_col: UInt16(newCols), ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(fd, TIOCSWINSZ, &size)
        }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {
        MainActor.assumeIsolated {
            let trimmed = title.trimmingCharacters(in: .whitespaces)
            self.title = trimmed.isEmpty ? Shell.displayName(of: shellPath) : trimmed
        }
    }

    nonisolated func scrolled(source: TerminalView, position: Double) {
        MainActor.assumeIsolated {
            guard !isRestoringScroll else { return }
            scrollFollow.didScroll(to: position, canScroll: view.canScroll)
            updateScrollerVisibility()
        }
    }

    /// Links come from whatever a program prints, including remote hosts over
    /// SSH, so only ordinary web, mail and file links are opened.
    nonisolated static let openableLinkSchemes: Set<String> = ["http", "https", "mailto", "file"]

    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(),
              Self.openableLinkSchemes.contains(scheme) else {
            DispatchQueue.main.async { NSSound.beep() }
            return
        }
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
    }

    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(content, forType: .string)
        }
    }

    nonisolated func bell(source: TerminalView) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.settings.settings.activity.bell, !self.isOnScreen {
                self.noteActivity(.bell)
            } else {
                NSSound.beep()
            }
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
}

private extension CursorStyle {
    init(_ shape: CursorShape, blinks: Bool) {
        switch shape {
        case .block: self = blinks ? .blinkBlock : .steadyBlock
        case .underline: self = blinks ? .blinkUnderline : .steadyUnderline
        case .bar: self = blinks ? .blinkBar : .steadyBar
        }
    }
}
