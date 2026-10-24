# LaunchGrid

A free, full-screen app grid for macOS 14+: pages, folders and type-to-search, one keystroke away. Everything is included; there are no purchases, licence checks, network calls or announcements.

About 99% of LaunchGrid (code, tests, documentation and website) was written by AI, Claude by Anthropic, directed and tested by Sébastien Lavoie. The app itself contains no AI features and makes no network connections.

## Install

Download `LaunchGrid.zip` from the [latest release](https://github.com/sglavoie/LaunchGrid/releases/latest), unzip it and move LaunchGrid to your Applications folder. Or use [Homebrew](https://brew.sh): `brew install --cask sglavoie/tap/launchgrid`, and `brew upgrade` for updates. It is signed and notarised, and runs on Apple silicon and Intel Macs with macOS 14 or later.

## Build and run

```sh
scripts/bundle.sh            # release build → build/LaunchGrid.app (ad-hoc signed, hardened runtime)
open build/LaunchGrid.app
scripts/install.sh           # build, quit the installed copy, replace /Applications/LaunchGrid.app, relaunch
swift test                   # core and app-state tests
```

With [just](https://github.com/casey/just), `just` lists shortcuts for these: `just install`, `just uninstall` (removes the login item, quits and deletes the app, keeps your layout and settings), `just run`, `just scratch` (a throwaway layout and separate settings, beside the installed copy, logs in the terminal), `just sandbox` (the build signed with the Mac App Store sandbox, so its layout and settings live in its container; quit the installed copy first), `just test`, `just test-app-store`, `just ci` and `just clean`.

CI (`.github/workflows/ci.yml`) builds, tests and bundles on macOS 26, runs the tests again against the Mac App Store variant (`just test-app-store`) and checks `scripts/*.sh` with shellcheck.

The website at [launchgrid.sglavoie.com](https://launchgrid.sglavoie.com/) (home, support and privacy policy) is static HTML in `website/public`, served by a Cloudflare Worker: `just website` previews it. Pushing a change under `website/` to `main` publishes it (`.github/workflows/website.yml`), after `scripts/check-website.sh` confirms that every file and `#anchor` the pages refer to exists (pull requests run the same check); `just website-deploy` does the same by hand. `docs/app-store-submission.md` tracks what the Mac App Store still needs. The video and Settings screenshots on the home page come from `just demo-video` (`scripts/record-demo.sh`), which drives a scratch copy through `scripts/demo/story.txt` and `scripts/demo/settings.txt` with the apps in `scripts/demo/apps.txt`; edit those and run it again to refresh them. It needs ffmpeg, cwebp and Screen Recording permission for the terminal you run it in.

Installing to `/Applications` is needed for "Open at login". `scripts/install.sh --no-open` skips the relaunch, and `INSTALL_DIR=~/Applications` installs elsewhere. It falls back to `sudo` when the folder isn't writable, and registers the installed copy as the `.launchgrid` handler. Only the copy at the install path is quit (LaunchGrid saves and quits on `SIGTERM`), so a `just scratch` run keeps going.

`just release` (`scripts/release.sh`) makes the downloadable build: universal, signed with your Developer ID (found in the keychain, or `SIGN_IDENTITY`), notarised, stapled and zipped to `build/release/LaunchGrid.zip`. The script's header describes the one-time notarisation setup. `just publish` (`scripts/publish.sh`) then creates the GitHub release for it and updates the Homebrew cask in [sglavoie/homebrew-tap](https://github.com/sglavoie/homebrew-tap). To release, bump `VERSION` in `scripts/bundle.sh`, commit, push, then run both. This build is **not sandboxed**, so it can scan any folder and read the old Launchpad/AppGrid databases without asking.

`just app-store` (`scripts/app-store.sh`) makes the Mac App Store build: the same code in the App Sandbox (`scripts/LaunchGrid.entitlements`), without the debug scripts, signed with Apple Distribution and packaged as `build/app-store/LaunchGrid.pkg`; `just app-store --upload` sends it to App Store Connect. The script's header describes the certificates and provisioning profile it needs. Inside the sandbox, LaunchGrid keeps security-scoped bookmarks to the extra scan folders, the custom background picture and apps added with Browse (`FileAccess` in `Services.swift`), and the AppGrid and Launchpad imports first ask for the database's folder. `~/Applications` is read through a temporary-exception entitlement. Both builds ship `scripts/PrivacyInfo.xcprivacy`.

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
| Pages | Swipe, scroll, ←/→, Tab, Page Up/Down, Home/End (first and last page), ⌘1…9, click the page dots |
| Esc | Clears search → closes folder (focus returns to it) → leaves edit mode → clears the selection → hides |
| Edit mode | ⌘E, long-press an icon, or ⋯ › Edit Layout. Clicking selects instead of launching; clicking a search result (or Return) shows it where it is, its folder open, with keyboard focus on it. ✕ removes an item; with the keyboard, Return renames the focused item (or the open folder), ⌫ removes it and ⌥ + arrow keys move it (with the rest of the selection) one slot, onto the next or previous page past either end |
| Select | ⌘-click / ⇧-click, ⌘A, or Space on the focused item. Then drag them together, **Group** (⌘G), **Remove** (⌫), or Move to Page |
| Drag & drop | Drop in a gap to reorder. Hold over an app for a moment to make a folder, or over a folder to add to it. Hold at the screen edge to flip pages, including onto a new page. Drag out of an open folder to take an app out |
| Folders | Click the title to rename. Ungroup from the context menu. A folder disappears when its last app leaves |
| Undo / redo | ⌘Z / ⇧⌘Z, 50 levels, including imports, rebuilds and resizes |
| Right-click | Item: Open, Show in Finder, Rename, Move to Page, Group, Remove. Background: page and sort actions. With the keyboard, ⌃Return opens the focused item's menu and ⇧⌃Return the ⋯ menu |

**Settings:**

- **General:** shortcut recorder with a conflict warning, open at login, Dock and menu-bar icons (monochrome or in the logo's colours), auto-add new apps (at the end of the grid, as Launchpad adds them), hide behaviour.
- **Appearance:** Full Screen, Full Screen Behind Dock, or a resizable Window (with frames saved per display). Backgrounds: blurred desktop, wallpaper, Liquid Glass, solid colour or custom image. Icon size and labels.
- **Layout:** grid rows × columns. Resizing re-flows every item in order, filling each page before the next, and asks first when items would change page; each page takes the title of the page its first item came from. Folder placement when sorting; Sort Everything also clears page titles.
- **Library:** choose which apps to include or exclude, add missing apps (also ones from anywhere via Browse), extra scan folders (flagged when missing or unreadable, as are unreadable folders inside the scan folders), save/load `.launchgrid` files (double-clicking one in Finder loads it too; `.appgrid` files from earlier builds still load), import from AppGrid or Launchpad, rebuild, regenerate icons.

## Where things live

- Layout: `~/Library/Application Support/LaunchGrid/grid.json`. This is pretty-printed, versioned JSON written atomically about 0.5 s after each change; the save before it is kept beside it as `grid.json.bak`. An unreadable file (or one from a newer version) is moved aside, never overwritten. An unreadable one is replaced by the backup when that can be read, with an alert saying so; otherwise the welcome window says where it went. If it can't be moved, nothing is saved until you move it yourself. A save that fails when you quit asks before quitting. Apps excluded in the welcome window are saved before the layout is made.
- Settings: `defaults read com.sglavoie.launchgrid`.
- Removed and excluded apps are remembered in the grid's `removedBundleIDs` (by path for a copy that shares its bundle ID, like Xcode-beta), so scans and rebuilds don't re-add them; *Choose Apps…* or *Add Missing Apps…* brings them back.

## How it's built

Two targets, each with a test target (`LaunchGridCoreTests`, `LaunchGridTests`):

- **`LaunchGridCore`**: pure, unit-tested logic.
  - `Model`: value-type `Grid`, which makes undo a snapshot.
  - `GridOps`: insert with overflow spill, move, group, reflow, sort.
  - `Reconciler`: add new apps, drop deleted ones, follow moved ones, keep the removed list. It never prunes on an empty scan, nor apps on an unmounted volume or under a scan folder that is missing or can't be listed.
  - `AppScanner`: depth-limited, symlink-cycle-safe, skips bundle contents.
  - `Search`, `GridStore`.
  - `LaunchpadImporter`: reads a copy of the database and its write-ahead log; it handles Apple's multi-root DB, AppGrid's `custom_path` and `manual_app_*` IDs, and nested folder pages.
- **`LaunchGrid`**: the AppKit/SwiftUI app.
  - `OverlayController`: a non-activating `NSPanel`, so it takes keyboard focus without fighting cooperative activation. It shows on the screen under the pointer and handles key and scroll input.
  - `Interaction`: one root `DragGesture` with arithmetic hit-testing, dwell timers for merge, reorder and edge-flip, and a live gap.
  - Carbon hotkey, FSEvents watcher with a debounced rescan (plus a 10-minute and on-wake fallback), icon cache rendered off the main thread, `SMAppService` login item.
  - User-facing strings go through `String(localized:)` or SwiftUI's `LocalizedStringKey`. `Localizable.xcstrings` holds their plural forms and, later, translations; `scripts/bundle.sh` compiles it into the bundle with `xcstringstool`, so `swift build` and the tests show the English keys.

**Development aid:** `LAUNCHGRID_DEBUG_SCRIPT="build:alpha;show;drag:0,3;merge:1,2;snap:x;quit"` drives the UI with synthesized events and writes window snapshots to `LAUNCHGRID_DEBUG_DIR`. It only runs together with `LAUNCHGRID_DATA_DIR`, so it never edits your real layout; otherwise it's ignored with a note on stderr. It's left out of the Mac App Store build. `LAUNCHGRID_DATA_DIR` points the app at a scratch layout and the `com.sglavoie.launchgrid.scratch` settings domain, and lets it run beside the installed copy (which keeps the global shortcut). See `Sources/LaunchGrid/DebugScript.swift`.

### Deliberately left out

- In-app purchases, licence checks and anything else that needs a network connection.
- Announcements and release notes inside the app.
- `.lmy` import, whose format is unverified. `.agrid` files load through the SQLite importer.

## Licence

MIT; see [LICENSE](LICENSE).
