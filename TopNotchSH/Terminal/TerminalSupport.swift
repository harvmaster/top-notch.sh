import AppKit

/// Shell discovery and the environment handed to each shell.
enum Shell {
    static func resolve(configuredPath: String) -> String {
        let candidates = [
            configuredPath,
            ProcessInfo.processInfo.environment["SHELL"] ?? "",
        ]
        return candidates
            .map { ($0.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath }
            .first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }
            ?? "/bin/zsh"
    }

    static func displayName(of path: String) -> String {
        (path as NSString).lastPathComponent
    }

    static func environment() -> [String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "TopNotchSH"
        // Apps launched from Finder/launchd have no locale; without one, shells
        // mangle UTF-8 input and output.
        if environment["LANG"] == nil, environment["LC_ALL"] == nil, environment["LC_CTYPE"] == nil {
            environment["LANG"] = "en_US.UTF-8"
        }
        return environment.map { "\($0.key)=\($0.value)" }
    }
}

enum TerminalFont {
    static func make(name: String, size: Double) -> NSFont {
        let size = CGFloat(size.clamped(to: TerminalSettings.fontSizeRange))
        if !name.isEmpty, let font = NSFont(name: name, size: size) {
            return font
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Regular-weight, upright monospaced fonts installed on this Mac, as (PostScript name, display name).
    static func availableMonospaced() -> [(name: String, displayName: String)] {
        let manager = NSFontManager.shared
        let excludedTraits: NSFontTraitMask = [.boldFontMask, .italicFontMask, .condensedFontMask, .expandedFontMask]
        return (manager.availableFontNames(with: .fixedPitchFontMask) ?? [])
            .compactMap { NSFont(name: $0, size: 13) }
            .filter { manager.traits(of: $0).isDisjoint(with: excludedTraits) && !$0.fontName.hasPrefix(".") }
            .map { ($0.fontName, $0.displayName ?? $0.fontName) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
}

/// Escape sequences that return the terminal to a sane input state.
enum TerminalModes {
    /// Pops every kitty keyboard mode a program pushed. Programs such as
    /// Claude Code turn it on, and while it is on, keys like ⌃C reach the
    /// shell as escape sequences it doesn't understand.
    static let popKeyboardModes = "\u{1b}[<99u"

    /// Input modes a program may have left on.
    static let inputModes = [
        "\u{1b}[?9l", "\u{1b}[?1000l", "\u{1b}[?1002l", "\u{1b}[?1003l", // mouse reporting
        "\u{1b}[?1004l",                     // focus reporting
        "\u{1b}[?1005l", "\u{1b}[?1006l", "\u{1b}[?1015l", "\u{1b}[?1016l", // mouse encodings
        "\u{1b}[?2004l",                     // bracketed paste
        "\u{1b}[?1l", "\u{1b}>",             // normal cursor keys and keypad
    ].joined()

    /// The sequence that undoes whatever a program left behind.
    ///
    /// Keyboard modes are kept per screen, so they are popped on the
    /// alternate screen before leaving it, and again on the main screen.
    /// Leaving the alternate screen also restores the cursor saved when the
    /// program started, so it is only sent when the alternate screen is on:
    /// otherwise the cursor would jump to a stale position.
    static func resetSequence(inAlternateScreen: Bool) -> [UInt8] {
        var sequence = ""
        if inAlternateScreen {
            sequence += popKeyboardModes + "\u{1b}[?1049l"
        }
        sequence += popKeyboardModes + inputModes
        return Array(sequence.utf8)
    }
}

/// Decides whether the viewport follows new output or stays where the user
/// scrolled to.
struct ScrollFollow {
    private(set) var followsOutput = true
    private(set) var anchor = 1.0
    var bottomThreshold = 0.999

    mutating func didScroll(to position: Double, canScroll: Bool) {
        let position = position.clamped(to: 0...1)
        guard canScroll, position < bottomThreshold else {
            reset()
            return
        }
        followsOutput = false
        anchor = position
    }

    /// Where to put the viewport after new output, or `nil` to follow it.
    func restorePosition(canScroll: Bool) -> Double? {
        canScroll && !followsOutput ? anchor : nil
    }

    /// Typing always snaps back to the prompt. Returns `true` if a jump is needed.
    mutating func userDidType() -> Bool {
        defer { reset() }
        return !followsOutput
    }

    mutating func reset() {
        followsOutput = true
        anchor = 1
    }
}

/// Geometry for translating wheel events into terminal mouse reports.
enum MouseWheel {
    struct Cell: Equatable {
        let column: Int
        let row: Int
        let pixelX: Int
        let pixelY: Int
    }

    static func ticks(for deltaY: Double) -> Int {
        switch Int(abs(deltaY)) {
        case 10...: 20
        case 6...: 10
        case 2...: 3
        default: 1
        }
    }

    /// `point` is in the view's (bottom-left origin) coordinates.
    static func cell(at point: CGPoint, in bounds: CGRect, cols: Int, rows: Int) -> Cell {
        let width = max(bounds.width, 1)
        let height = max(bounds.height, 1)
        let x = point.x.clamped(to: 0...width)
        let yFromTop = height - point.y.clamped(to: 0...height)
        let cols = max(cols, 1)
        let rows = max(rows, 1)

        return Cell(
            column: min(Int(x / (width / CGFloat(cols))), cols - 1),
            row: min(Int(yFromTop / (height / CGFloat(rows))), rows - 1),
            pixelX: Int(x),
            pixelY: Int(yFromTop)
        )
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// Escapes paths the way Terminal.app does when files are dropped on it.
enum ShellEscaping {
    private static let special = Set(" \t\n'\"\\()[]{}<>&;|$`!*?#~=%^,")

    static func escape(_ path: String) -> String {
        path.reduce(into: "") { result, character in
            if special.contains(character) {
                result.append("\\")
            }
            result.append(character)
        }
    }
}
