# Top NotchSH

A terminal that lives under the notch on macOS. A rebuild of CommandNotch: SwiftTerm only, no hover-to-open, smaller and simpler.

## Build

Requires macOS 14+, Xcode 16+, and `brew install xcodegen`.

```bash
xcodegen generate
open TopNotchSH.xcodeproj        # Xcode asks once to trust SwiftTerm's build-info plugin
```

From the command line:

```bash
xcodegen generate
xcodebuild -project TopNotchSH.xcodeproj -scheme TopNotchSH -skipPackagePluginValidation build
xcodebuild -project TopNotchSH.xcodeproj -scheme TopNotchSH -skipPackagePluginValidation test
./scripts/build-dmg.sh           # → dist/TopNotchSH.dmg
```

### End-to-end self-test

Debug builds include a self-test that drives the real app. It spawns shells, sends real key events through the input router, and reads the terminal buffers to check the results. It also checks layout and animation timing, writes `report.txt` and screenshots to a folder, then quits. It uses a throwaway settings store, doesn't register ⌘⏎, and takes keyboard focus for about 35 seconds:

```bash
"build/…/Debug/Top NotchSH.app/Contents/MacOS/Top NotchSH" --self-test /tmp/tnsh-selftest
```

SwiftTerm is pinned to `1.20.x`. The `1.99.x` series doesn't compile with Xcode 26.3; there's an error inside SwiftTerm's `PowerlineRenderer.swift`.

## Shortcuts

| Shortcut | Action | Works |
| --- | --- | --- |
| ⌘⏎ | Toggle notch | everywhere |
| ⌘T / ⌘W | New / close tab | open notch |
| ⌘⇧] / ⌘⇧[ | Next / previous tab | open notch |
| ⌘1 … ⌘9 | Go to tab | open notch |
| ⌘⇧↓ / ⌘⇧↑ | Next / previous workspace | open notch |
| ⌘D | Move tab to its own window | open notch |
| ⌘⇧1 / 2 / 3 | Size presets | open notch |
| **⌘R** | **Reset terminal input modes** | any terminal |
| ⌘= / ⌘- / ⌘0 | Font size bigger / smaller / reset | any terminal |
| ⌘← / ⌘→, ⌘⌫, ⌘L | Start/end of line, delete line, clear | any terminal |
| ⌥← / ⌥→ | Move by word (when Option is used as Meta) | any terminal |

Everything except ⌘1–9 and the editing keys can be changed in Settings → Hotkeys. Each workspace can also have its own jump shortcut.

⌘R puts the terminal back into a normal input state after a program crashes and leaves it broken (for example, mouse movement printing junk). It turns off mouse reporting, bracketed paste and application cursor keys, leaves the alternate screen, and does a soft reset. The shell itself isn't restarted.

## Architecture

```
TopNotchSH/
├── App/          TopNotchSHApp (menu bar), AppModel (composition root)
├── Settings/     AppSettings (one Codable value), SettingsStore, TerminalTheme
├── Input/        Command, HotkeyAction, KeyChord, InputRouter, GlobalHotkey
├── Terminal/     TerminalSession (SwiftTerm + shell), TerminalKeyMap, TerminalSurface
├── Workspaces/   Workspace (tabs), WorkspaceStore (persistence)
├── Notch/        NotchCoordinator (all screens), NotchController (one screen),
│                 NotchPanel, ScreenGeometry, Views/
├── Windows/      Settings window, pop-out terminal windows
├── SettingsUI/   Settings pages, hotkey recorder
└── Support/      JSONDefaults, LaunchAtLogin
```

How the pieces fit:

- **One way to trigger anything.** Every user action is a `Command`. Hotkeys (`InputRouter`), menu items and buttons all produce commands, and `NotchCoordinator.perform(_:)` is the only place that carries them out.
- **One settings value.** `AppSettings` is a single `Codable` struct stored as one JSON blob. When loading, the saved JSON is merged over the defaults, so a new setting gets its default value without any migration code. Hotkeys are stored as `[HotkeyAction: KeyChord]`, so a new `HotkeyAction` case automatically gets a default, a settings row and persistence.
- **One controller per screen.** `NotchController` owns its screen's phase, size and panel. All movement goes through `transition(to:size:animation:)`. That function enlarges the panel before an animation and shrinks it afterwards, so a closed notch covers only the notch itself and doesn't block clicks on the menu bar.
- **One key and scroll monitor**, shared by every tab and window, instead of two event monitors per session.

## Changes from CommandNotch

- **Ghostty removed.** Built on SwiftTerm only. The ~1,400-line Ghostty backend, the vendored xcframework, its themes and terminfo are gone.
- **Hover-to-open removed**, along with its timers, suppression flags and hover animation settings. You can click the closed notch to open it.
- **Padding is configurable**, separately for the built-in notched display and for other displays (Settings → Notch). Two causes of text disappearing at the bottom are also fixed:
  - The SwiftUI safe-area inset is turned off, so content no longer gets pushed down by the notch height.
  - The header is now exactly as tall as the hardware notch, so the terminal starts just below it.
- **Smoother animations.** During open, close and resize, the terminal is laid out once at its final size and revealed by the animating shape. Before, the shell was resized on every animation frame.
- **Other additions:**
  - ⌘R input reset
  - ⌘= / ⌘- / ⌘0 font zoom
  - Monospaced font picker
  - Cursor shape and blink settings
  - Option-as-Meta toggle
  - Four more themes, with a live preview
  - Setting for the open notch's corner radius
  - Option to keep the notch open when another app takes focus
- **Tabs:**
  - New tabs open in the current tab's working directory, read from the shell process.
  - When a shell exits, its tab closes.
  - The active tab scrolls into view.
- **Workspaces:**
  - Workspaces start their shells only when first shown.
  - You can rename a workspace inline and delete it from the notch.
  - Each display gets a workspace picker in Settings.
- **Mouse wheel:** in `less`, `man` and similar programs, the wheel scrolls the program's own view.
- **Environment:** `LANG` is set when the app is launched from Finder, so UTF-8 input and output work in the shell.
- **Settings are stored separately.** The bundle ID is different (`com.topnotchsh.app`), so CommandNotch's settings aren't carried over.

## License

MIT
