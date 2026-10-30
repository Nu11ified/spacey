<p align="center"><img src="packaging/logo/logo-256.png" width="128" alt="Spacey"></p>

# Spacey

A simple, keyboard-first window manager for macOS 26, built for multiple
monitors and for [Rex](https://www.superlogical.com/rex).

Spacey is early but in daily use. Its core logic is covered by a regression
suite.

## Modes

A mode is a named context you fill yourself, such as Build, Research, Chat,
Write or Music. It spans every screen. Build can hold Rex on the portrait
monitor, a browser on the wide one, and Slack on the laptop. One key switches
every screen at once.

- New windows join the mode you're in. Move one with Option-Shift-number.
- Option-Shift-0 shows a window in every mode, for example to keep chat
  beside whatever you're doing.
- Each window remembers its screen separately for every combination of
  connected displays. Unplug at the end of the day and everything collapses
  onto the laptop. Plug back in and each window returns to its own screen.
- Each screen tiles its share of the mode: side by side on landscape screens,
  stacked on portrait ones. Option-S and Option-Shift-S switch layouts for that
  screen and mode.
- Windows in other modes are parked just past a screen corner, so switching
  is instant, with no minimize animation and no Dock clutter.
- Fullscreen windows are left alone, and the bar and dock stay out of their
  Space.

### Apple Intelligence

When a new window opens, Apple's on-device model can suggest which mode it
belongs in, based only on the app name, the window title and your mode names.
The suggestion appears in the bar as a chip. Click it to move the window;
nothing moves on the model's word alone. This needs Apple Intelligence turned
on in System Settings.

## Bar and dock

The top bar replaces the macOS menu bar, which still slides in when the pointer
reaches the top edge. On each screen it shows your modes (the active one by
name, the others by number, with a dot when they hold windows) and the focused
window. The main screen also shows Rex status, keep-awake, battery and the
clock. Click the clock for Spacey's menu.

The dock on the main screen shows the modes and the current mode's apps, with
Rex's waiting count on its icon.

## Rex

Agents like Claude Code report their state to Rex through the
[Program Status Protocol](https://www.superlogical.com/rex/docs/build/program-status):
working, finished, blocked on a question or permission, or failed. Spacey
follows Rex's event stream.

- Option-` opens the inbox: panes that need you, then agents still working.
  Use the arrow keys and return, or press 1–9, to jump to the exact session, tab and pane.
- Option-Shift-` jumps straight to the most urgent pane.
- A toast appears when an agent blocks or fails while you're elsewhere, and the
  bar shows the waiting count.

## Keys

| Keys | Action |
| --- | --- |
| Option-1 … 9 | Switch mode |
| Option-Shift-1 … 9 | Move the focused window to a mode |
| Option-Shift-0 | Show the focused window in every mode (again to undo) |
| Option-Space | Back to the previous mode |
| Option-H / J / K / L | Focus left / down / up / right, across screens |
| Option-Shift-H / J / K / L | Swap with the window in that direction |
| Option-Control-← / → | Move the focused window to the previous / next screen |
| Option-Tab | Cycle windows in the mode |
| Option-F | Focus: show only this window (again to undo) |
| Option-S / Option-Shift-S | Stack / side by side, on this screen |
| Option-Q / Option-Shift-Q | Close the window / quit the app |
| Option-B, Return, R, … | Open an app, or a new window if it's already in front |
| Option-` / Option-Shift-` | Rex inbox / jump to the most urgent pane |
| Option-Control-Escape | Pause and put every window back |

## Config

`~/.config/spacey/config.json` is optional, and any field you leave out keeps
its default. Choose **Edit modes…** in the menu to create it, then **Reload
config**.

```json
{
  "gap": 10,
  "dock": true,
  "modes": [
    { "name": "Build", "icon": "hammer.fill", "color": "#5B8CFF", "apps": [] },
    { "name": "Chat", "icon": "bubble.left.and.bubble.right.fill", "color": "#3DDC84",
      "apps": ["com.tinyspeck.slackmacgap"] }
  ],
  "launch": { "b": "app.zen-browser.zen", "return": "com.mitchellh.ghostty", "r": "com.superlogical.rex" }
}
```

`icon` is an SF Symbol name. `apps` lists bundle IDs that always open in that
mode. Moving a window by hand overrides that. `launch` maps Option-letter (or
`return`) to an app.

Scripts and other apps can drive Spacey with URLs: `spacey://mode/2`,
`spacey://move/3`, `spacey://solo`, `spacey://pause`, `spacey://resume`,
`spacey://reload`, `spacey://inbox`, `spacey://jump`, `spacey://awake`.
`~/Library/Application Support/Spacey/status.json` reports the current state.

## Build and install

Requires macOS 26 and Swift 6.2 (Xcode or the Command Line Tools).

```sh
swift run SpaceyChecks            # regression checks
bash scripts/build-app --install  # builds and installs ~/Applications/Spacey.app
```

The build is signed with your Apple Development identity when one exists, so
the Accessibility permission survives rebuilds. Spacey starts managing
windows as soon as it has that permission. It waits while AeroSpace is
running.

## How it works

Spacey uses public APIs only: Accessibility, AppKit, Carbon hotkeys, IOKit
power assertions and Foundation Models. It uses no private SkyLight calls,
needs no SIP changes, and doesn't create Mission Control Spaces. Moves briefly
turn off `AXEnhancedUserInterface` so Chrome and Electron windows don't
animate.

`WorkspaceCore` holds the pure logic (modes, screens, tiling, parking, config
and the Rex board), and that's what the checks exercise. `Sources/Spacey` is
the app.

State lives in `~/Library/Application Support/Spacey/desktop.json`. It's
written atomically, and a file that can't be read is never overwritten.

## License

MIT
