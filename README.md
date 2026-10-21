# LaunchGrid

A free, Launchpad-style app grid for macOS 14+, rebuilt from the observed behaviour of AppGrid. Every former "Pro" feature is included; there are no purchases, licence checks, network calls or announcements.

## Build and run

```sh
scripts/bundle.sh            # release build → build/LaunchGrid.app (ad-hoc signed, hardened runtime)
open build/LaunchGrid.app
scripts/install.sh           # build, quit any running copy, replace /Applications/LaunchGrid.app, relaunch
swift test                   # core and app-state tests
```

With [just](https://github.com/casey/just), `just` lists shortcuts for these: `just install`, `just uninstall` (keeps your layout and settings), `just run`, `just scratch` (a throwaway layout and separate settings, beside the installed copy, logs in the terminal), `just test`, `just ci` and `just clean`.

CI (`.github/workflows/ci.yml`) builds, tests and bundles on macOS 26.

Installing to `/Applications` is needed for "Open at login". `scripts/install.sh --no-open` skips the relaunch, and `INSTALL_DIR=~/Applications` installs elsewhere. It falls back to `sudo` when the folder isn't writable, and registers the installed copy as the `.appgrid` handler.

Set `SIGN_IDENTITY="Developer ID Application: …"` before `scripts/bundle.sh` to sign for notarisation. The app is deliberately **not sandboxed**, so it can scan any folder, use FSEvents and read the old Launchpad/AppGrid databases directly.

On first launch, a welcome window lets you choose which installed apps to include (all by default), then offers these ways to set up the grid:

- Build by category.
- Build alphabetically.
- Import from AppGrid (if its database exists).
- Import from Launchpad (if the pre-macOS 26 database still exists).
- Load a grid file.

## Using it

| | |
|---|---|
| Show / hide | **⌥Space** (change in Settings), the menu-bar icon, or the Dock icon |
| Launch | Click, or arrow keys + Return |
| Search | Just type. Results rank prefix > word start > initials ("vsc") > substring > fuzzy. Return opens the first result |
| Pages | Swipe, scroll, ←/→, Tab, ⌘1…9, click the page dots |
| Esc | Clears search → closes folder (focus returns to it) → leaves edit mode → hides |
| Edit mode | ⌘E, long-press an icon, or ⋯ › Edit Layout. Clicking selects instead of launching. ✕ removes an item; with the keyboard, Return renames the focused item (or the open folder) and ⌫ removes it |
| Select | ⌘-click / ⇧-click, ⌘A, or Space on the focused item. Then drag them together, **Group** (⌘G), **Remove** (⌫), or Move to Page |
| Drag & drop | Drop in a gap to reorder. Hold over an app for a moment to make a folder, or over a folder to add to it. Hold at the screen edge to flip pages, including onto a new page. Drag out of an open folder to take an app out |
| Folders | Click the title to rename. Ungroup from the context menu. A folder disappears when its last app leaves |
| Undo / redo | ⌘Z / ⇧⌘Z, 50 levels, including imports, rebuilds and resizes |
| Right-click | Item: Open, Show in Finder, Rename, Move to Page, Group, Remove. Background: page and sort actions |

**Settings:**

- **General:** shortcut recorder with a conflict warning, open at login, Dock and menu-bar icons (monochrome or in the logo's colours), auto-add new apps, hide behaviour.
- **Appearance:** Full Screen, Full Screen Behind Dock, or a resizable Window (with frames saved per display). Backgrounds: blurred desktop, wallpaper, Liquid Glass, solid colour or custom image. Icon size and labels.
- **Layout:** grid rows × columns, with re-flow that keeps page boundaries; folder placement when sorting.
- **Library:** choose which apps to include or exclude, add missing apps (also ones from anywhere via Browse), extra scan folders, save/load `.appgrid` files (double-clicking one in Finder loads it too), import from AppGrid or Launchpad, rebuild, regenerate icons.

## Where things live

- Layout: `~/Library/Application Support/LaunchGrid/grid.json`. This is pretty-printed, versioned JSON written atomically about 0.5 s after each change. An unreadable file (or one from a newer version) is moved aside, never overwritten, and the welcome window says where it went.
- Settings: `defaults read com.sglavoie.launchgrid`.
- Removed and excluded apps are remembered in the grid's `removedBundleIDs` (by path for a copy that shares its bundle ID, like Xcode-beta), so scans and rebuilds don't re-add them; *Choose Apps…* or *Add Missing Apps…* brings them back.

## How it's built

Two targets, each with a test target (`LaunchGridCoreTests`, `LaunchGridTests`):

- **`LaunchGridCore`**: pure, unit-tested logic.
  - `Model`: value-type `Grid`, which makes undo a snapshot.
  - `GridOps`: insert with overflow spill, move, group, reflow, sort.
  - `Reconciler`: add new apps, drop deleted ones, follow moved ones, keep the removed list. It never prunes on an empty scan, nor apps on an unmounted volume or under a missing scan folder.
  - `AppScanner`: depth-limited, symlink-cycle-safe, skips bundle contents.
  - `Search`, `GridStore`.
  - `LaunchpadImporter`: reads a copy of the database and its write-ahead log; it handles Apple's multi-root DB, AppGrid's `custom_path` and `manual_app_*` IDs, and nested folder pages.
- **`LaunchGrid`**: the AppKit/SwiftUI app.
  - `OverlayController`: a non-activating `NSPanel`, so it takes keyboard focus without fighting cooperative activation. It shows on the screen under the pointer and handles key and scroll input.
  - `Interaction`: one root `DragGesture` with arithmetic hit-testing, dwell timers for merge, reorder and edge-flip, and a live gap.
  - Carbon hotkey, FSEvents watcher with a debounced rescan (plus a 10-minute and on-wake fallback), icon cache rendered off the main thread, `SMAppService` login item.

**Development aid:** `LAUNCHGRID_DEBUG_SCRIPT="build:alpha;show;drag:0,3;merge:1,2;snap:x;quit"` drives the UI with synthesized events and writes window snapshots to `LAUNCHGRID_DEBUG_DIR`. `LAUNCHGRID_DATA_DIR` points the app at a scratch layout and the `com.sglavoie.launchgrid.scratch` settings domain, and lets it run beside the installed copy (which keeps the global shortcut). See `Sources/LaunchGrid/DebugScript.swift`.

### Deliberately left out

- RevenueCat, StoreKit, the paywall and the licence check.
- `messages.json` announcements and release notes.
- `.lmy` import, whose format is unverified. `.agrid` files load through the SQLite importer.
