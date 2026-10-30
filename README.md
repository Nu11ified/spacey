# FocusWM prototype

A native macOS 26 window-management experiment. Starts paused. It refuses to
enable while AeroSpace is running. It is not yet a daily-driver replacement.

## Run

```sh
swift build
swift run --skip-build FocusWMChecks
swift run --skip-build FocusWM --inspect
bash scripts/build-app
open dist/FocusWM.app
```

The inspection command is read-only and prints display geometry, Accessibility
availability, an eligible-window count, and the on-device model's availability.
It does not print window titles or change window state.

To trial management, first turn the existing SketchyBar AeroSpace switch off so
its recovery loop will not restart it. Quit AeroSpace, launch this app, grant
Accessibility permission to FocusWM, and choose Enable management in its menu.
The first trial adopts existing eligible windows into workspace 1. Reassign
them once using Option-Shift-number; subsequent topology changes retain those
memberships. Use Option-Control-Escape to pause and restore manager-minimized
windows. The existing dotfiles configuration is untouched by this project.

To go back, pause/quit FocusWM, start AeroSpace, and turn the SketchyBar switch on.

## Keyboard

| Shortcut | Action |
| --- | --- |
| Option-1 through Option-9 | Select logical workspace |
| Option-Shift-1 through Option-Shift-9 | Assign focused window to a workspace |
| Option-Tab | Cycle windows in the selected workspace |
| Option-S | Top-and-bottom tiles |
| Option-Shift-S | Side-by-side tiles |
| Option-Control-Escape | Restore manager-minimized windows and pause |

Focus modes are All displays, Focus workspace, and Focus one window. These are
FocusWM modes, not changes to Apple's notification Focus settings.

## Persistent state

`~/Library/Application Support/FocusWM/desktop.json` holds workspace membership,
per-display layout overrides, selected workspaces, the focus mode, and the
minimization ownership journal. Writes are atomic and mode 0600. Invalid or
unknown-version state is rejected without overwriting the original file.

Each set of connected display UUIDs has a separate routing profile. A new
profile defaults to left-to-right, then top-to-bottom groups (5/4 for two
displays, 3/3/3 for three). Reconnecting restores the saved profile. Single-screen
fallback preserves all nine logical workspaces. Window records never change
workspace because a screen disappears. Layout defaults follow screen geometry,
and manual layout overrides are retained per workspace and display UUID.

Window identity uses the current Accessibility object while an app is running.
After a restart, it reattaches only when the app plus Accessibility identifier or
title has one matching record. Ambiguous windows are treated as new rather than
silently assigned to the wrong saved window. Identical unnamed app windows are
an unresolved macOS identity limitation; persistence across every app restart is
not guaranteed. Current-process HDMI transitions do not depend on window titles.

## Native integration

Uses public ApplicationServices Accessibility APIs for standard, movable,
resizable windows; AppKit for screen/workspace notifications; and Carbon global
hotkeys. It does not use private SkyLight APIs or disable SIP. Window observation
is event-driven and debounced. Apps have short AX messaging timeouts. A refused
tile size is reported and is not repeatedly hammered; Retry refused window sizes
lets the user retry. System dialogs, non-resizable windows, and fullscreen windows
are excluded. Nested split trees and custom floating rules are not implemented.

Logical workspaces use per-window native minimization. This avoids parking hidden
windows offscreen, but may animate and populate the Dock. Pause/Quit restores only
windows minimized by FocusWM. After an abnormal exit, the menu offers restoration
from its saved ownership journal. Native Mission Control Spaces are not created.
This visibility strategy needs real application and disconnect/reconnect testing
before replacing the current desktop setup.

## Apple Intelligence

The optional Classify focused window command uses Foundation Models with a
constrained generation schema. After confirmation it provides the app identifier
and a truncated window title to the on-device model. Suggestions do not move
windows. No screenshots, message bodies, cloud requests, continuous inference,
or notification access are used. Urgency is not established without explicit
metadata evidence. Full "needs me" detection requires source-specific integrations
such as agent completion events or unread-message signals. AI availability is
checked at runtime, and all window management works without the model.

## Research

- [Apple AXObserver](https://developer.apple.com/documentation/applicationservices/1460133-axobservercreate)
- [Apple display reconfiguration callbacks](https://developer.apple.com/documentation/coregraphics/cgdisplayreconfigurationcallback)
- [Foundation Models and classification](https://developer.apple.com/videos/play/wwdc2025/286/)
- [SystemLanguageModel availability](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)
- [Rectangle Accessibility adapter](https://github.com/rxhanson/Rectangle/blob/main/Rectangle/AccessibilityElement.swift)
- [Amethyst](https://github.com/ianyh/Amethyst)
- [Swindler](https://github.com/tmandry/Swindler)

These implementations are references, not bundled source or runtime dependencies.
Tariq's post has not yet been identified; no behavior is attributed to it.
