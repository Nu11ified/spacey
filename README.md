<p align="center"><img src="packaging/logo/logo-256.png" width="128" alt="Spacey"></p>

# Spacey

A keyboard-first window manager for macOS 26: categories of work, each with
nine workspaces, laid out per monitor and remembered per desk. Built for
multiple monitors and for [Rex](https://www.superlogical.com/rex).

Spacey is early but in daily use. Its core logic is covered by a regression
suite.

## Categories, workspaces and profiles

Open **Set up Spacey** (Option-Comma, or the grid button in the bar) to see
everything in one place: your monitors drawn to scale with the categories on
each, every category's nine workspaces and the windows in them, and every
shortcut. From there you can add a category to a monitor or move it to another
one, switch a monitor between side by side and one at a time, move any window
to any category and workspace (a workspace can hold several), and rename, add
or delete categories.

Windows are sorted into **categories**, such as Agents, Browser, Comms, Notes
and Media. Each category has **workspaces 1–9**, and each workspace holds one
window. A new window takes its category's next empty workspace.

Each **monitor** holds the categories you put on it. A vertical monitor can show
Comms on top and Browser below, each on its own current workspace. A screen
shows its categories either side by side or one at a time; Option-Control-S
switches between the two. A category with nothing in its current workspace
gives its space to the others.

A category can also live on **several monitors**, with Browser on two screens
for example. Each monitor then shows its own workspace of that category, and
Option-letter followed by a number changes the copy on the monitor you're on. Picking
a workspace that's already showing on another monitor swaps the two. In setup,
**+ Add** puts a category on a monitor without taking it off the others, and ×
takes it off one monitor. Taking a category off its last monitor parks its
windows and lists it under "Not on a monitor". Spacey leaves it there until you
add it back, or press its Option-letter to bring it to the monitor you're on.

A **profile** is one monitor arrangement, such as the desk or the laptop alone.
Spacey keeps one for each set of connected displays and switches as monitors
come and go. Unplug and the laptop profile takes over; plug back in and every
category returns to its screen. Name a profile from the menu.

### Apple Intelligence

**Regroup with Apple Intelligence** (in the menu) asks Apple's on-device model
to propose categories from the windows you have open. A new window from an app
that no category claims is sorted by the model. Moving a window by hand
overrides both and teaches Spacey where that app belongs. Without Apple
Intelligence, built-in knowledge of common apps does the sorting. The model
sees only app names, bundle IDs and window titles, and nothing leaves the Mac.

When a window that isn't on screen comes forward (a link opened from Slack, Cmd-Tab,
a new window), it **takes over the area you were working in** rather than
appearing somewhere else. That monitor's bar then shows a **↩** button with
what the area showed before, such as ↩ Comms 1, and clicking it puts that back.
Picking a workspace for that area also ends the takeover.

Windows in workspaces that aren't showing are parked just past a screen corner,
so switching is instant. Fullscreen windows are left alone, and the bar and
dock stay out of their Space.

## Bar and dock

Each monitor's bar lists the categories on that monitor: the letter, the name,
and the workspaces that hold windows, with the current workspace filled. Click a
category or a number to switch. The main screen also shows Rex status,
keep-awake, battery and the clock. Click the clock for Spacey's
menu. The macOS menu bar slides in when the pointer reaches the top edge.

The dock on the main screen shows the categories and the apps in the focused
category.

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
| Option-letter | Focus a category (A Agents, B Browser, C Comms, N Notes, M Media) |
| Option-letter, then 1–9 | That category's workspace, within about a second |
| Option-1 … 9 | Workspace of the focused category |
| Option-Shift-letter | Move the focused window to a category |
| Option-Shift-1 … 9 | Move the focused window to a workspace |
| Option-Control-letter | Put a category on the monitor you're on |
| Option-Control-S | This monitor: side by side, or one category at a time |
| Option-Tab | Next workspace with a window, in the focused category |
| Option-Space | Back to the previous category and workspace |
| Option-H / J / K / L | Focus left / down / up / right, across screens |
| Option-Shift-H / J / K / L | Swap with the window in that direction |
| Option-F | Show only this window (again to undo) |
| Option-S / Option-Shift-S | Stack / side by side within the category |
| Option-Q / Option-Shift-Q | Close the window / quit the app |
| Option-Comma | Set up Spacey: screens, categories, windows, shortcuts |
| Option-` / Option-Shift-` | Rex inbox / jump to the most urgent pane |
| Option-Control-Escape | Pause and put every window back |

## Config

Categories, profiles and workspaces are managed from the menu and saved in
`~/Library/Application Support/Spacey/desktop.json`.
`~/.config/spacey/config.json` is optional:

```json
{
  "gap": 10,
  "dock": true,
  "categories": [
    { "id": "agents", "name": "Agents", "letter": "a", "icon": "terminal.fill", "color": "#5B8CFF",
      "apps": ["com.superlogical.rex", "com.mitchellh.ghostty"] }
  ]
}
```

Leave `categories` out to let Spacey and Apple Intelligence manage them. When
it's set, it replaces them. `icon` is an SF Symbol name. Letters H, J, K, L, F,
S and Q are taken by other keys.

Scripts can drive Spacey with URLs: `spacey://focus/browser`,
`spacey://workspace/browser/2`, `spacey://move/comms`, `spacey://solo`,
`spacey://pause`, `spacey://resume`, `spacey://reload`, `spacey://inbox`, `spacey://add/browser/2` and
`spacey://remove/browser/2` (screens counted left to right), `spacey://restore`,
`spacey://jump`, `spacey://awake`. `~/Library/Application
Support/Spacey/status.json` reports the current state.

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

`WorkspaceCore` holds the pure logic (categories, workspaces, profiles, tiling,
parking and the Rex board), and that's what the checks exercise. `Sources/Spacey` is
the app.

State lives in `~/Library/Application Support/Spacey/desktop.json`. It's
written atomically, and a file that can't be read is never overwritten.

## License

MIT
