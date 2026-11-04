# Top NotchSH

A terminal that lives under the notch on macOS. A rebuild of CommandNotch: SwiftTerm only, no hover-to-open, smaller and simpler.

## Build

Requires an Apple silicon Mac with macOS 14+, Xcode 16+, and `brew install xcodegen`.

```bash
xcodegen generate
open TopNotchSH.xcodeproj        # Xcode asks once to trust SwiftTerm's build-info plugin
```

From the command line:

```bash
xcodegen generate
xcodebuild -project TopNotchSH.xcodeproj -scheme TopNotchSH -skipPackagePluginValidation build
xcodebuild -project TopNotchSH.xcodeproj -scheme TopNotchSH -skipPackagePluginValidation test
```

### Release DMG

```bash
./scripts/release.sh                 # build, sign, notarize and staple → dist/TopNotchSH-<version>.dmg
./scripts/release.sh --no-notarize   # quick signed build without notarizing
./scripts/release.sh --help
```

The script builds an Apple silicon app and signs it with the hardened runtime. It then packages the app into a styled drag-to-Applications DMG and signs the DMG. It picks the best identity in your keychain: Developer ID Application, then Apple Development, then ad-hoc. `SIGN_IDENTITY=…` overrides the choice.

With a Developer ID certificate, the script also notarizes by default, using the keychain profile `top-notchsh`. That makes the DMG open on any Mac without Gatekeeper warnings. One-time setup:

1. Xcode → Settings → Accounts → your team → Manage Certificates → **+** → Developer ID Application.
2. Create an app-specific password at account.apple.com, then run the command below. It prompts for the password and stores it in the Keychain.
   `xcrun notarytool store-credentials top-notchsh --apple-id <you> --team-id <TEAMID>`

Notarization is only needed for builds other people download, from GitHub releases or Homebrew. Builds made on your own Mac run without it.

The first run may ask to let your terminal control Finder; this lays out the DMG window.

## Configuration

Configuration lives in `~/.config/top-notchsh/` as pretty-printed JSON:

| File | Contents |
| --- | --- |
| `settings.json` | Every setting, including hotkeys and size presets. Hand edits apply immediately. |
| `workspaces.json` | Workspaces: name, jump shortcut, startup folder and command, saved tabs. |
| `displays.json` | Which workspace each display shows. |

Keys you leave out use their defaults, so a minimal file works. If a file is invalid, it's moved aside to `*.json.invalid` rather than overwritten, and defaults are used. A typo saved while the app is running is ignored until it's fixed. Settings from earlier builds, which used `UserDefaults`, are migrated on first launch.

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
| ⌘⇧T | Reopen the last closed tab, in its folder | open notch |
| ⌘⇧] / ⌘⇧[ | Next / previous tab | open notch |
| ⌘1 … ⌘9 | Go to tab | open notch |
| ⌘⇧↓ / ⌘⇧↑ | Next / previous workspace | open notch |
| ⌘D | Move tab to its own window | open notch |
| ⌘⇧1 / 2 / 3 | Size presets | open notch |
| ⌘⇧P | Pin the notch open | open notch |
| ⌘F, ⌘G / ⌘⇧G | Find, next / previous match | any terminal |
| **⌘R** | **Reset terminal input modes** | any terminal |
| ⌘= / ⌘- / ⌘0 | Font size bigger / smaller / reset | any terminal |
| ⌘← / ⌘→, ⌘⌫, ⌘L | Start/end of line, delete line, clear | any terminal |
| ⌥← / ⌥→ | Move by word (when Option is used as Meta) | any terminal |

Everything except ⌘1–9 and the editing keys can be changed in Settings → Hotkeys. Each workspace can also have its own jump shortcut.

⌘R puts the terminal back into a normal input state after a program crashes and leaves it broken (for example, mouse movement printing junk). It turns off mouse reporting, bracketed paste and application cursor keys, leaves the alternate screen, and does a soft reset. The shell itself isn't restarted.

## Features

- **Tabs.** Drag to reorder: the other tabs slide aside to preview the new order. Double-click or right-click a tab to rename it. Tabs come back after a restart, in their last folders and with their names (turn this off in Settings → General).
- **Workspaces.** Each workspace can have its own jump shortcut, startup folder, and a startup command that is typed into every new tab (e.g. `ssh my-server`).
- **Activity.** When a tab you aren't looking at rings the bell or finishes a long command, the closed notch widens and shows a glowing indicator, and the tab gets a dot. You can choose the triggers in Settings → General.
- **Pinning.** A pinned notch stays open while you work in other apps. ⌘⏎ brings it forward instead of closing it.
- **Files.** Drop files onto the terminal to type their escaped paths. Dragging files over the closed notch opens it.
- **Privacy.** Hide the notch and pop-out windows from screen sharing and recordings. Toggle it from the menu bar icon. It's off by default.
- **Translucency.** The background opacity and blur can be adjusted; text stays crisp, and the closed notch stays solid black.

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
