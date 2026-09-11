<div align="center">

<img src="anchor/Assets.xcassets/AppIcon.appiconset/anchor-256.png" width="140" alt="Anchor app icon">

# Anchor

**Put a task down. Pick it back up.**

A macOS menu bar app for saving your working layout and returning to it later.

</div>

## Keep your place

A course might be a browser on the left and PyCharm on the right. A project might
be an IDE, a terminal, and a handful of reference tabs. Switching tasks usually
means taking that arrangement apart, then finding everything again when you return.

Anchor saves the supported apps, tabs, projects, terminal directories, and window
positions on your current screen as one layout. Pick it later to reopen that context
and put its windows back where they belong.

## Save, recognize, return

Click the anchor in the menu bar and a small panel drops down beside it. Your saved
layouts sit in a grid, three across, each one a miniature of its window arrangement
with the apps' icons inside, so you can recognize a setup without opening it. Give a
layout a name if you want, or keep its app-based label.

The grid runs oldest to newest, so the newest layouts are at the bottom, which is
where the panel opens. Scroll up for older ones. **New anchor point** sits in the
bottom-left corner, next to settings, and saves whatever is on your screen now.

Pick a layout and choose:

| Action | What happens |
| --- | --- |
| **Open alongside** | Reopens the saved layout while keeping your current windows. |
| **Save & switch** | Saves your current layout, closes the selected current windows, then opens the saved one. |
| **Switch without saving** | Switches layouts without creating another save of the current setup. |

The layout screen keeps to the panel's size: a back arrow, the layout's name, a
larger preview, and those three actions. Warnings stay on it when they apply, and if
Anchor cannot close something a switch would have to close, it says so and asks you
to decide before anything runs. Applications still handle their own unsaved-work
prompts. Canceling or encountering a failure stops further closing and reports what
happened.

Saved layouts stay until you delete them. The three-dot menu beside a layout's name
lets you rename it or move its saved record to Trash; your actual projects and files
stay put.

## What comes back

- **Browser context:** saved addresses, tab order, and the selected tab where supported.
- **Projects:** the project or workspace in its IDE, with available editor context
  captured separately. The IDE may also restore its own editor state.
- **Terminal context:** a new local shell at a captured working directory.
- **Your arrangement:** supported windows repositioned and resized for the destination screen.

Current integrations target Safari, Chrome, Terminal, iTerm2, PyCharm, CLion, and
Xcode. Safari, Terminal, and the IDEs have been exercised during development;
Chrome and iTerm2 still need live validation. Capabilities vary by app, and Anchor
shows partial results instead of pretending everything was recovered.

## Local by design

No account or cloud sync. Layouts are stored on your Mac, and saving happens when
you ask for it—there is no automatic background snapshotting yet.

Browser capture is optional, and the settings menu in the bottom-left corner of the
panel turns it on or off, alongside diagnostics and quit. When enabled, saves include
full URLs and tab titles. Private-window exclusion is not guaranteed, so turn browser
capture off when you do not want that content saved.

## Try it

Anchor is in active development. The current project targets **macOS 26.5 or later**.

1. Clone this repository and open `anchor.xcodeproj` in Xcode.
2. Build the `anchor` scheme, choosing a local signing team if needed.
3. Under Products, reveal `anchor.app` in Finder and open it from there for everyday use.
4. Grant Accessibility access for window controls, and Automation access for the
   apps you want Anchor to work with when prompted.

## A few boundaries

Anchor currently works with one screen's visible desktop at a time. It does not
recreate macOS Spaces, native fullscreen, or Split View arrangements. IDE welcome
screens remain a known rough edge; save an open project instead.

A saved layout is not a backup of unsaved edits or a frozen application session.
Browser Back/Forward history, running terminal commands, SSH/tmux sessions, and
exact editor state are not restored. Pages blocked by browser extensions may not
reopen as expected.

For those looking under the hood: Anchor is a native Swift app using AppKit and
SwiftUI, Accessibility, and app-specific capture/restore integrations. It runs
unsandboxed and keeps versioned JSON records in
`~/Library/Application Support/Anchor/Snapshots/`.
