import AppKit
import SwiftTerm

/// Built-in terminal color schemes.
enum TerminalTheme: String, Codable, CaseIterable, Identifiable {
    case classic
    case xterm
    case solarizedDark
    case dracula
    case nord
    case oneDark
    case gruvboxDark
    case tokyoNight
    case catppuccinMocha

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: "Classic"
        case .xterm: "Xterm"
        case .solarizedDark: "Solarized Dark"
        case .dracula: "Dracula"
        case .nord: "Nord"
        case .oneDark: "One Dark"
        case .gruvboxDark: "Gruvbox Dark"
        case .tokyoNight: "Tokyo Night"
        case .catppuccinMocha: "Catppuccin Mocha"
        }
    }

    var palette: Palette {
        switch self {
        case .classic:
            Palette(foreground: 0xE5E5E5, background: 0x000000, ansi: [
                0x000000, 0xC23621, 0x25BC24, 0xADAD27, 0x492EE1, 0xD338D3, 0x33BBC8, 0xCBCCCD,
                0x818383, 0xFC391F, 0x31E722, 0xEAEC23, 0x5833FF, 0xF935F8, 0x14F0F0, 0xE9EBEB,
            ])
        case .xterm:
            Palette(foreground: 0xE5E5E5, background: 0x000000, ansi: [
                0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
                0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
            ])
        case .solarizedDark:
            Palette(foreground: 0x839496, background: 0x002B36, ansi: [
                0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
                0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3,
            ])
        case .dracula:
            Palette(foreground: 0xF8F8F2, background: 0x282A36, ansi: [
                0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
                0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF,
            ])
        case .nord:
            Palette(foreground: 0xD8DEE9, background: 0x2E3440, ansi: [
                0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
                0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4,
            ])
        case .oneDark:
            Palette(foreground: 0xABB2BF, background: 0x282C34, ansi: [
                0x282C34, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF,
                0x5C6370, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xFFFFFF,
            ])
        case .gruvboxDark:
            Palette(foreground: 0xEBDBB2, background: 0x282828, ansi: [
                0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
                0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2,
            ])
        case .tokyoNight:
            Palette(foreground: 0xC0CAF5, background: 0x1A1B26, ansi: [
                0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
                0x414868, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xC0CAF5,
            ])
        case .catppuccinMocha:
            Palette(foreground: 0xCDD6F4, background: 0x1E1E2E, ansi: [
                0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE,
                0x585B70, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8,
            ])
        }
    }
}

extension TerminalTheme {
    /// Colors stored as 0xRRGGBB.
    struct Palette {
        let foreground: UInt32
        let background: UInt32
        let ansi: [UInt32]

        var foregroundColor: NSColor { .hex(foreground) }
        var backgroundColor: NSColor { .hex(background) }

        /// The 16 ANSI colors in SwiftTerm's 16-bit-per-channel format.
        var ansiColors: [SwiftTerm.Color] {
            ansi.map { hex in
                SwiftTerm.Color(
                    red: UInt16((hex >> 16) & 0xFF) * 257,
                    green: UInt16((hex >> 8) & 0xFF) * 257,
                    blue: UInt16(hex & 0xFF) * 257
                )
            }
        }
    }
}

extension NSColor {
    static func hex(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
