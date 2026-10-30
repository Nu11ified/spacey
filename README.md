# Spacey

A keyboard-driven window manager for macOS 26, built around
[Rex](https://www.superlogical.com/rex). It gives you nine workspaces that
survive unplugging monitors, and an inbox of the Rex panes that need you.

Spacey is early. It works on the author's machine and is covered by a
regression suite for its core logic, but it hasn't had broad real-world use.

## Rex

Agents like Claude Code report what they're doing to Rex through the
[Program Status Protocol](https://www.superlogical.com/rex/docs/build/program-status)
(OSC 7501): working, finished, blocked on a question or permission, or failed.
Spacey follows the Rex server's event stream and keeps a live picture of every
pane.

| Shortcut | Action |
| --- | --- |
| Option-` | Open the Rex inbox: panes that need you, then agents still working |
| Option-Shift-` | Jump straight to the most urgent pane |

In the inbox, use ↑ ↓ and return, or press 1–9, to jump. Jumping switches to
the workspace that holds Rex, raises it, and focuses the exact session, tab
and pane.

- Blocked panes rank first, then failures, then finished work you haven't
  looked at. Bells and terminal notifications count too.
- When an agent blocks or fails while Rex is in the background, a toast
  appears in the corner. Click it to jump.
- The menu bar shows how many panes are waiting.
- Looking at a pane in Rex marks it seen.

The Rex shortcuts work even while workspace management is paused, so you can
use the inbox alongside another window manager.

Spacey never starts a Rex server. It reconnects quietly when Rex restarts.
To see what the inbox would show, run `swift run Spacey --rex`.

## Workspaces

| Shortcut | Action |
| --- | --- |
| Option-1 … 9 | Go to workspace |
| Option-Shift-1 … 9 | Move the focused window to a workspace |
| Option-Tab | Cycle windows in the workspace |
| Option-S / Option-Shift-S | Stack top and bottom / side by side |
| Option-Control-Escape | Pause and put every window back |

Each set of connected displays gets its own profile, which maps workspaces to
screens and remembers what each screen was showing. Unplug the dock and the
laptop keeps all nine workspaces. Plug it back in and every screen returns to
where it was. A window's workspace never changes because a screen
disappeared. Portrait screens stack windows and landscape screens put them
side by side, unless you choose otherwise.

Hidden windows are parked just past a screen corner instead of minimized, so
switching is instant, with no genie animation and no Dock clutter. The corner
is chosen so a parked window never peeks onto a neighbouring monitor.

Focus modes, from the menu, show all displays, only the focused workspace, or
only the focused window.

## Build and run

Requires macOS 26 and Swift 6.2 (Xcode or the Command Line Tools).

```sh
swift build
swift run SpaceyChecks        # regression checks
swift run Spacey --inspect    # read-only: displays, permissions, window count
bash scripts/build-app        # builds dist/Spacey.app
open dist/Spacey.app
```

Spacey starts paused. Grant it Accessibility access, then choose **Enable
management** from its menu. It refuses to enable while AeroSpace is running.
On first enable, every existing window joins workspace 1. Sort them once with
Option-Shift-number; the assignments are kept from then on.

## State

`~/Library/Application Support/Spacey/desktop.json` holds workspace
membership, display profiles, layout choices, focus mode, and a journal of
the windows Spacey moved offscreen. Writes are atomic with mode 0600. A file
that can't be read is left untouched.

After a restart, windows are matched back to their workspace by app plus
accessibility identifier or title, and only when exactly one record matches.
Two untitled windows of the same app can't be told apart; they're treated as
new.

## How it works

Spacey uses public APIs only: Accessibility to observe and move windows,
AppKit for screens and app lifecycle, and Carbon for global shortcuts. It uses
no private SkyLight calls, needs no SIP changes, and doesn't create Mission
Control Spaces.

Moves briefly turn off `AXEnhancedUserInterface`, which otherwise makes Chrome
and Electron windows animate every move.

`WorkspaceCore` holds the pure logic (workspace routing, layout, parking,
and the Rex board) and is what the checks exercise. `Sources/Spacey` is the
app: the macOS adapter, the Rex bridge, and the overlays.

There's an optional, opt-in command to classify the focused window with
Apple's on-device model (Foundation Models). It sees only the app identifier
and a truncated title, and it never moves anything.

## Not done yet

- Nested split trees and floating-window rules
- Configurable shortcuts and workspace names
- Real-world testing across many apps and dock/undock cycles

## License

MIT
