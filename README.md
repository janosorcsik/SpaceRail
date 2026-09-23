# SpaceRail

Fast virtual workspaces for macOS, without macOS Spaces.

A workspace is a set of **windows**. Switching to it brings those windows to the front, puts them back where you left them, and focuses the one you used last. Nothing else moves, hides or disappears — the rest of your windows stay where they are, behind.

## How it works

- **Attach** the focused window to a workspace with its shortcut. Attach again to detach.
- **Switch** to a workspace and its windows come forward in their saved layout.
- Click or ⌘-tab to a window that belongs to another workspace and SpaceRail follows you there.
- Quit an app and relaunch it later: its windows are re-adopted into their workspace and placed where they were. Switching to a workspace whose app isn't running launches it.
- A **HUD** shows every workspace with the apps in it; it hides itself after a moment.

## Default shortcuts

All of them can be changed in Settings. The examples assume ⌃⌥⌘ ("hyper") — produce it however you like (Caps Lock remap, Karabiner, or just hold the three keys).

| Action | Default |
| --- | --- |
| Switch to workspace *n* | <kbd>⌃⌥⌘</kbd> <kbd>n</kbd> |
| Attach / detach the focused window to workspace *n* | <kbd>⌃⌥⌘⇧</kbd> <kbd>n</kbd> |
| Show / hide the HUD | <kbd>⌃⌥⌘</kbd> <kbd>H</kbd> |

Settings lets you rename workspaces, add and remove them, record any shortcut per workspace, set the HUD auto-hide delay and enable launch at login.

## Requirements

- macOS 26 or later
- Accessibility permission (the app asks on first launch; no restart needed after granting)

## Build

The Xcode project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`; shared settings live in `Config.xcconfig`.

```sh
brew install xcodegen
make run        # build the dev app ("SpaceRail Dev", own bundle ID) and launch it
make test       # unit tests (model and geometry; never launches the app)
make install    # archive Release and install to /Applications
make logs       # stream the app's logs
make help       # everything else
```

`make generate` alone produces `SpaceRail.xcodeproj` for working in Xcode. The dev build has its own bundle identifier, Accessibility grant, shortcuts and state directory, so it runs side by side with the installed app.

The only dependency is [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) (Carbon hotkeys — no event tap, works under Secure Input).

## Design notes

See [`docs/PLAN.md`](docs/PLAN.md) for the decisions behind the current design and [`docs/ISSUES.md`](docs/ISSUES.md) for the analysis of the previous, app-hiding version.
