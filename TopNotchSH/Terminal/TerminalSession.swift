import AppKit
import Combine
import Darwin
import SwiftTerm

/// A SwiftTerm view that knows its owning session, so input routing can map
/// the first responder back to a session.
final class SessionTerminalView: TerminalView {
    weak var session: TerminalSession?
}

/// One shell process and the terminal view that renders it.
@MainActor
final class TerminalSession: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    let view: SessionTerminalView

    @Published private(set) var title: String

    /// Called once the shell process exits.
    var onExit: (() -> Void)?

    private let shellPath: String
    private let launchDirectory: String
    private var process: LocalProcess?
    private var appliedSettings: TerminalSettings?
    private var scrollFollow = ScrollFollow()
    private var isRestoringScroll = false
    private var settingsSubscription: AnyCancellable?

    init(settings: SettingsStore, directory: String?) {
        let configuration = settings.settings.terminal
        shellPath = Shell.resolve(configuredPath: configuration.shellPath)
        launchDirectory = directory ?? NSHomeDirectory()
        title = Shell.displayName(of: shellPath)
        view = SessionTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        super.init()

        view.session = self
        view.terminalDelegate = self
        installClipboardHandler()
        updateScrollerVisibility(animated: false)
        settingsSubscription = settings.publisher(\.terminal)
            .sink { [weak self] in self?.apply($0) }
    }

    // MARK: - Lifecycle

    func start() {
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
    }

    func terminate() {
        onExit = nil
        process?.terminate()
        process = nil
    }

    func focus() {
        view.window?.makeFirstResponder(view)
    }

    /// The shell's working directory, used so new tabs open where you are.
    var currentDirectory: String? {
        if let pid = process?.shellPid, pid > 0, let directory = Self.workingDirectory(of: pid) {
            return directory
        }
        return view.getTerminal().hostCurrentDirectory.flatMap { URL(string: $0)?.path }
    }

    // MARK: - Commands

    /// Restores sane input state after a program exits without cleaning up:
    /// stray mouse reports, bracketed paste, application cursor keys and the
    /// alternate screen. The shell itself is not touched.
    func resetInputModes() {
        view.feed(byteArray: TerminalModes.resetSequence[...])
        view.getTerminal().softReset()
        view.selectNone()
        scrollFollow.reset()
        view.scroll(toPosition: 1)
        updateScrollerVisibility()
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
            self.view.feed(byteArray: TerminalModes.resetSequence[...])
            self.onExit?()
        }
    }

    /// SwiftTerm delivers data on the main queue (the default for `LocalProcess`).
    nonisolated func dataReceived(slice: ArraySlice<UInt8>) {
        MainActor.assumeIsolated {
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
            if scrollFollow.userDidType() {
                view.scroll(toPosition: 1)
                updateScrollerVisibility()
            }
            process?.send(data: data)
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

    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link) else { return }
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
    }

    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(content, forType: .string)
        }
    }

    nonisolated func bell(source: TerminalView) {
        DispatchQueue.main.async { NSSound.beep() }
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
