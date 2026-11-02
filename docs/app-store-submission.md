# Mac App Store submission

**Rules reviewed October 21, 2026; sandbox acceptance updated November 1, 2026.** What Apple requires before LaunchGrid can be accepted on the Mac App Store, what is already done, and what is left. Apple's rules change: re-read the [sources](#sources) before submitting.

## Summary

- **The website is ready.** `website/` holds the home page, privacy policy and support page for `launchgrid.sglavoie.com`.
- **The App Store code variant has passed the available sandbox checks below, including a fresh login.** A genuine legacy Launchpad database was unavailable on the test MacBook. The distribution certificates and provisioning profile are present on the development Mac. `just app-store` builds the sandboxed, signed package (see [What's done in the app](#whats-done-in-the-app)); packaging and submission of the current changes remain separate release steps.
- **The repository is public** under the MIT licence, so the support page's issue links work.
- The rest is App Store Connect paperwork.

## URLs for App Store Connect

| Field | URL | Required |
| --- | --- | --- |
| Privacy Policy URL | `https://launchgrid.sglavoie.com/privacy/` | Yes, for every app (5.1.1(i)) |
| Support URL | `https://launchgrid.sglavoie.com/support/` | Yes; must lead to real contact information (1.5) |
| Marketing URL | `https://launchgrid.sglavoie.com/` | No |

Guideline 2.1(a) rejects "empty websites and other temporary content", so deploy the site before entering these. Once the app is approved, replace "A Mac App Store version is on the way" on the home page ("Get LaunchGrid") with the App Store link, using Apple's official badge from the [marketing resources](https://developer.apple.com/app-store/marketing/guidelines/).

## What's done in the app

| Requirement | Change |
| --- | --- |
| Privacy policy linked **inside the app** (5.1.1(i)) and an easy way to contact the developer (1.5) | "LaunchGrid Support" and "Privacy Policy" in the menu-bar icon's menu and the app menu (`AppDelegate.swift`) |
| Export compliance | `ITSAppUsesNonExemptEncryption = false` in `scripts/bundle.sh`. LaunchGrid uses no encryption, so App Store Connect stops asking at each upload |
| Copyright | `NSHumanReadableCopyright` is "© 2026 Sébastien Lavoie" |
| App Sandbox (2.4.5(i)) | `scripts/LaunchGrid.entitlements`; see [Sandbox](#1-app-sandbox) |
| Privacy manifest | `scripts/PrivacyInfo.xcprivacy`; see [Privacy manifest](#2-privacy-manifest) |
| Packaging with Xcode's tools (2.4.5(ii)) | `scripts/app-store.sh`; see [Packaging](#3-packaging-and-signing) |

### 1. App Sandbox

The App Store build is signed with the sandbox, `files.user-selected.read-write` (the save and open panels), `files.bookmarks.app-scope` and `temporary-exception.files.home-relative-path.read-only` for `/Applications/` (`~/Applications`; see below). The downloadable build stays unsandboxed; the code checks `Sandbox.isActive` at run time, so both builds share it.

| Feature | Inside the sandbox |
| --- | --- |
| Scanning `/Applications` and `/System/Applications`, FSEvents | Work unchanged |
| Scanning `~/Applications` | The real home comes from `getpwuid` (`Sandbox.realHome`), and the `temporary-exception.files.home-relative-path.read-only` entitlement for `/Applications/` makes it readable. **Explain it in the review notes** (below). If review refuses it, drop the entitlement: people can still add the folder under Extra folders |
| Scanning Homebrew's `opt` folders (`/opt/homebrew/opt`, `/usr/local/opt`), for apps installed by formulae such as Python's IDLE | Skipped when `Sandbox.isActive`: reading them would take another temporary exception. People can add `/opt/homebrew` under Extra folders (not `opt` itself: its links lead into `Cellar`, outside that folder's bookmark); casks put their apps in `/Applications` anyway |
| Extra scan folders, custom background picture, apps added with Browse | Read-only security-scoped bookmarks, saved when picked and reopened at launch and when a volume mounts (`FileAccess` in `Services.swift`) |
| Wallpaper background | Pictures outside readable locations fall back to the blurred desktop, and Settings says so, suggesting Custom Image |
| Launchpad and AppGrid imports | Their databases are still found (existence checks work outside the sandbox; the Launchpad folder drops the container's suffix that `confstr` adds). Importing opens a panel on the database's folder; one click on Allow grants it, the database and its write-ahead log |
| Layout and settings | In `~/Library/Containers/com.sglavoie.launchgrid`, apart from the downloadable build's |
| Debug scripts (`DebugScript.swift`) | Compiled out (`-DAPP_STORE`), with their synthetic events |
| Shortcut conflict warning (`KeyCombo` in `Services.swift`) | Doesn't read `com.apple.symbolichotkeys` (compiled out, and unreadable in the sandbox anyway), so it can't tell a system shortcut turned off from one still on: the warning says "unless that shortcut is off" |
| Launching, Show in Finder, `.launchgrid` files from Finder, Carbon hotkey, `SMAppService` | Work unchanged. Open at Login is off until the person turns it on, which satisfies 2.4.5(iii) |
| Actions: links, files and Apple Shortcuts | Links go to `NSWorkspace.open` (LaunchGrid makes no connection). A file or app picked for an action gets a read-only security-scoped bookmark, as Browse does. Shortcuts run through the `shortcuts://` URL scheme, so no Shortcuts entitlement or automation access is needed |
| Actions: shell commands | Not available: `Process` can't run user commands in the sandbox, so command actions show as unavailable and the editor says they need the website version. Compiled to that under `-DAPP_STORE`, and also when `Sandbox.isActive` |
| Actions: user scripts | Run with `NSUserUnixTask` / `NSUserAppleScriptTask` from `~/Library/Application Scripts/com.sglavoie.launchgrid/`, which only the person can write to. macOS runs them outside the sandbox, in its own `UserScriptService`, so LaunchGrid can't stop one once it has started. **No new entitlement**; see [User scripts](#user-scripts-and-review) |

Earlier checks: a sandboxed build (`SANDBOX=1 scripts/bundle.sh`) found the same 128 apps as the unsandboxed one, including the five in `~/Applications`. Tested by hand on October 24, 2026: an app added from `~/Downloads` with Browse kept its bookmark across relaunches and followed moves, including after removal from the grid and while LaunchGrid was running. A database copy with its write-ahead log was also imported through Load Grid File… and its folder Allow panel.

#### Sandbox acceptance — October 31–November 1, 2026

UI testing ran on **Seb's MacBook Pro over SSH**, with a logged-in graphical session, macOS 27.0.1 (26A434), Apple silicon and Xcode 27.2 (27B52). The tested source was `f2ef5ef` plus the database-folder access fix, now committed as `bbce5f2`; the committed source matched the tested source by SHA-256. The app was compiled with `APP_STORE=1`, signed ad hoc with the actual sandbox entitlements, and checked with `codesign --verify --strict`. Debug script and UI test driver strings were absent. The embedded profile was a stand-in, so these results establish runtime sandbox behavior, not distribution signing or App Store acceptance.

| Check | Result and evidence |
| --- | --- |
| First launch | The welcome window appeared with an empty grid and a real scan found 126 apps. Closing the welcome window built the category layout. |
| Extra folder across relaunch | Added a folder in Downloads using Add Folder…. After quitting and relaunching, the folder remained readable without a warning. A second fixture app added afterward appeared automatically on the saved grid. |
| Custom image across relaunch | Chose an image outside the container with the image picker. After relaunch, Appearance still showed Custom Image and `background.jpg`, without a read warning; both the image and folder bookmarks remained saved. A remote screenshot confirmed the image rendered as the grid background. |
| Save and load | Saved through NSSavePanel and compared the export with `grid.json`. After replacing the layout with an imported database, loaded the export through NSOpenPanel and confirmed complete JSON equality, including IDs, pages and folders. |
| Import a database copy | Loaded an AppGrid-schema `.agrid` fixture from a separate folder in Documents. The folder Allow panel appeared. Import confirmation found both apps, including Notes, which existed only in the SQLite write-ahead log. Canceling replacement preserved the complete grid. Accepting imported the fixture apps; SHA-256 checks confirmed the source database and WAL were unchanged. |
| Native AppGrid import action | No genuine AppGrid database was present on this MacBook. A temporary fixture at AppGrid's expected database path exercised Settings › Library › Import from AppGrid…. The actual App Store code variant requested its folder and reported “Imported 2 apps from AppGrid”, including the WAL-only app. The source database and WAL were unchanged. |
| Native Launchpad import | No legacy Launchpad database was present on this MacBook, so a genuine legacy import could not be exercised. Its folder-permission dialog could be canceled without replacing the layout. The shared importer and WAL handling were exercised by the AppGrid fixtures above. |
| Open at Login | From `/Applications/LaunchGrid.app`, toggling on reported Enabled; that status survived quitting and relaunching. Toggling off reported Off, and toggling on again reported Enabled. **Fresh login passed November 1:** after the user logged out and back in, the console session ID changed and the original app process was gone. A new process was already running from `/Applications` at the login time, before any test activation or launch command. The installed binary was unchanged, Settings reported Enabled, the custom image rendered, and ⌥Space opened the grid. A new fixture app added after login appeared automatically within 4.3 seconds, verifying restored folder access and watcher delivery. |
| Global shortcut | From Finder, ⌥Space opened the installed sandboxed grid. |
| Existing regression suites | All 238 tests passed in each of the normal and `-DAPP_STORE` variants. All four fixture-based UI scenarios passed on the MacBook, with 32 state checkpoints. |

The import fixture exposed a failure in the old folder-permission flow: pressing Allow still produced “Choose the folder that holds the … database”. The code ignored the security-scoped URL returned by the folder picker. `readDatabase` now starts access through that URL, retains it while the background importer reads the database and WAL, and balances it with `stopAccessingSecurityScopedResource()` before asking to replace the layout. Permission cancellation also completes the queued load. See Apple's [security-scoped URL lifetime documentation](https://developer.apple.com/documentation/foundation/url/startaccessingsecurityscopedresource()).

To reproduce the regression, use a database outside the container and outside any bookmarked scan folder, with a committed app entry only in its live WAL. Select the database file through Load Grid File…, then press Allow for its containing folder. Both apps must reach the replacement confirmation; cancel must preserve the grid, and accepting must import the WAL entry without modifying the source files. Repeat from Import from AppGrid… with a database at its expected path. Run this on the MacBook over SSH, not on the development Mac.

The available sandbox acceptance checks are complete. After the fresh-login check, the temporary login item and installed app were removed, the test folders were archived outside Downloads and Documents, and the original MacBook sandbox container was restored. All 37 files and links in the restored container matched the original backup. `just sandbox --keep` remains useful for repeating persistence checks; without `--keep`, the container is reset for each run. A genuine pre-macOS 26 Launchpad database remains an additional compatibility check when one is available. Distribution packaging and App Store submission remain release steps.

#### User scripts and review

The question review is most likely to ask about actions is whether LaunchGrid runs code it didn't ship with (guideline 2.5.2: apps may not "download, install, or execute code which introduces or changes features or functionality of the app"). It doesn't download or install anything. The Mac App Store build runs only scripts the person wrote and put in the app's Application Scripts folder themselves, through `NSUserUnixTask` and `NSUserAppleScriptTask`. That folder and those classes are Apple's sanctioned mechanism for a sandboxed app to run user scripts: the app can read the folder but not write to it, so nothing the app or a grid file contains can become a script there. Shell commands, which would need `Process`, are left out of this build.

Grid files can carry actions, so a file someone shares can't run anything on load: loading one lists its commands, scripts and links to other apps, in full, and every action in it opens in the editor the first time it is run, until the person saves it there. Saving a grid file leaves commands and scripts out unless the person ticks "Include commands and scripts".

**No entitlement was added** for actions: `scripts/LaunchGrid.entitlements` is unchanged (no `com.apple.security.automation.apple-events`, no `scripting-targets`, no new temporary exception). If review asks, add to the review notes: "Actions can open links, files and Apple Shortcuts, and run scripts the user saves in ~/Library/Application Scripts/com.sglavoie.launchgrid through NSUserUnixTask and NSUserAppleScriptTask. LaunchGrid never writes to that folder and downloads no code. Shell commands are not available in the Mac App Store version."

### 2. Privacy manifest

`Contents/Resources/PrivacyInfo.xcprivacy`, in both builds: no tracking, no collected data, and these APIs.

| API category | Where | Reason |
| --- | --- | --- |
| User defaults | `Preferences.swift`, `FileAccess` | `CA92.1` (the app's own defaults) |

No file timestamps are read. A scratch run's marker (`AppDelegate.isScratch`) holds the run's start time, from `sysctl`, so a stale one is told apart without the marker's creation date. The icon cache no longer reads other apps' modification dates, for which no approved reason fits: it spots an app updated in place by its Info.plist versions and icon name. System boot time was only read by the debug scripts, which the App Store build leaves out.

### 3. Packaging and signing

`just app-store` (`scripts/app-store.sh`) needs a clean working tree, then:

1. Reads the team ID from the provisioning profile, and checks the profile is for `com.sglavoie.launchgrid`.
2. Builds universal with `-DAPP_STORE`, adds Xcode's build keys (`DTXcode`, `DTSDKName`…), which App Store Connect uses to check the SDK, and embeds the profile.
3. Signs with **Apple Distribution** and the sandbox entitlements plus `com.apple.application-identifier` and `com.apple.developer.team-identifier`.
4. Wraps the app with `productbuild`, signed with the **Mac Installer Distribution** certificate, into `build/app-store/LaunchGrid.pkg`.

`just app-store --upload` sends the package with `xcrun altool` and an App Store Connect API key (IDs in `private/app-store-connect.env`, the `.p8` in `~/.appstoreconnect/private_keys`); the Transporter app works too. One-time setup in [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/):

- **Present on October 31, 2026:** Apple Distribution and 3rd Party Mac Developer Installer signing identities, in addition to Apple Development and Developer ID Application.
- The explicit App ID is `com.sglavoie.launchgrid` (no capabilities needed).
- **Present on October 31, 2026:** `private/LaunchGrid.provisionprofile`, named “LaunchGrid App Store”, for the expected App ID; it expires October 21, 2027. The file is git-ignored (or set `PROVISIONING_PROFILE` to another path).

`CFBundleVersion` is the commit count, which rises with each commit, as App Store Connect requires. The icon set already includes the 1024 px (`512@2x`) size.

## Names, licence and contact

### 4. Names, trademarks and the AppGrid origin

- **4.1 (copycats) and 5.2.1 (intellectual property).** Done: the README describes LaunchGrid on its own terms, with no comparison to AppGrid's paid features. The name, icon and interface are distinct. Keep it that way in the App Store description.
- **2.3.7 (metadata).** Keep "Launchpad" and "AppGrid" out of the name, subtitle and keywords. The description may say factually that it can import an older Launchpad layout. "Launchpad" is Apple's trademark; Apple's [trademark guidelines](https://www.apple.com/legal/intellectual-property/guidelinesfor3rdparties.html) allow referring to it in plain text, not as part of your product's branding.
- **Name availability.** App Store Connect rejects a name another developer already uses; reserve "LaunchGrid" when creating the app record.

### 5. Open-sourcing

- Done: `sglavoie/LaunchGrid` is public under the MIT licence.
- Reviewers sometimes reject support pages whose only contact needs an account. If that happens, add an email address (for example a Cloudflare Email Routing alias) to the support page's summary box.

## App Store Connect

| Item | Answer or note |
| --- | --- |
| Membership | Paid Apple Developer Program (99 USD a year) |
| Price | Free; no Paid Apps agreement needed |
| Category | Utilities (matches `LSApplicationCategoryType`); Productivity as secondary |
| Name and subtitle | 30 characters each. For example, "LaunchGrid" and "Full-screen app grid and search" |
| Keywords | 100 characters, no trademarks: app launcher, grid, folders, apps, shortcut, keyboard, organize… |
| Screenshots | 1 to 10, 16:10, at 1280×800, 1440×900, 2560×1600 or 2880×1800; showing the app in use (2.3.3), not the welcome window alone. `just app-store-screenshots` records five at 2880×1800 into `docs/app-store/screenshots` (`scripts/demo/app-store.txt`): the grid, search, a folder, edit mode and Settings, in Window mode over a system wallpaper |
| App Privacy | Data Not Collected |
| Age rating | Answer the questionnaire; every answer is "none", which gives the lowest rating |
| EU trader status | Required to be available in the EU under the Digital Services Act. A trader has the address, phone and email given to Apple shown on the product page in the EU. A free hobby app may qualify as non-trader; leaving out the EU is the other option |
| Review contact | Name, email and a phone number in international format; not shown publicly |
| Review notes | LaunchGrid lives in the menu bar (`LSUIElement`). ⌥Space shows the grid; right-click the menu-bar icon for Settings. The welcome window appears on first launch. Actions (links, files, Shortcuts and user scripts) are described under [User scripts](#user-scripts-and-review); add that paragraph if review asks about running scripts. For the entitlement: "LaunchGrid is an app launcher. It reads ~/Applications (read-only, through com.apple.security.temporary-exception.files.home-relative-path.read-only) because macOS and browsers install apps there, such as Chrome and Safari web apps, and a launcher that left them out would be incomplete. It only lists the app bundles there and reads their names, icons and Info.plist; it writes nothing." |
| Copyright | 2026 Sébastien Lavoie |
| App Sandbox information | On the version page, under App Review Information, click + and add `com.apple.security.temporary-exception.files.home-relative-path.read-only` (the only temporary exception; the other entitlements need no reason) with: "LaunchGrid is an app launcher: it shows the apps installed on the Mac in a grid. macOS, browsers and installers put apps in ~/Applications as well as /Applications (for example Chrome and Safari web apps, and apps installed for one user only), so the launcher reads that folder, read-only, to list them. It only lists the app bundles there and reads their names, icons and Info.plist files; it writes nothing and reads nothing else in the home folder." |
| AI disclosure | Not required by the guidelines for AI-written code; they cover AI only where an app shares personal data with a third-party AI (5.1.2(i)), which LaunchGrid doesn't. To match the website, end the description with: "About 99% of LaunchGrid was written with AI (Claude, by Anthropic). The app contains no AI features and makes no network connections." Keep it out of the name, subtitle and keywords (2.3.7) |

### Promotional text and description

Plain text: App Store Connect shows no Markdown, so the headings are capitals and the lists use "•". Promotional text (145 of 170 characters) can change at any time without a new review; the description (1820 of 4,000) changes only with a new version. Both keep "Launchpad" to a plain factual mention (2.3.7), leave out AppGrid, and end the description with the AI disclosure above.

Promotional text:

```text
Every app on your Mac, one keystroke away. Press ⌥Space, type a few letters and go. Pages, folders and fast search: free, with no data collected.
```

Description:

```text
LaunchGrid puts every app on your Mac in a full-screen grid, one keystroke away. Press ⌥Space, find what you need and get back to work.

FIND APPS FAST
• Just start typing. Results rank names that start with what you typed first, then word starts, initials ("vsc" finds Visual Studio Code), any match and near misses.
• Press Return to open the first result, or move around with the arrow keys.
• Swipe, scroll or press ⌘1 to ⌘9 to switch pages.

ORGANISE IT YOUR WAY
• Hold an app over another to make a folder, or select several and press ⌘G.
• Rename apps and folders, move apps between pages, and remove the ones you don't use.
• Sort everything alphabetically, or lay out every app by category in one step.
• Undo and redo up to 50 changes, including rebuilds.
• Works with the keyboard throughout: Esc steps back, Return opens or renames.

MAKE IT YOURS
• Full Screen, Full Screen with Dock, or a resizable window.
• Backgrounds: blurred desktop, your wallpaper, Liquid Glass (macOS 26), a solid colour or a picture of your own.
• Choose the number of rows and columns, the icon size and whether names show.
• Set your own shortcut, open LaunchGrid at login, and keep it in the Dock, the menu bar or both.

STAYS UP TO DATE
• Apps you install appear on the grid by themselves, and apps you delete leave it.
• Choose which apps to include; the ones you exclude stay off the grid.
• Save your layout to a file and load it on another Mac, or bring over your old Launchpad layout if your Mac still has one.

PRIVATE BY DESIGN
LaunchGrid is free: no purchases, accounts, ads or tracking. It collects no data, and your layout and settings stay on your Mac.

Requires macOS 14 or later.

About 99% of LaunchGrid was written with AI (Claude, by Anthropic). The app contains no AI features and makes no network connections.
```

## Sources

Read on October 21, 2026:

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/): 1.5, 2.1, 2.3.7, 2.4.5, 4.1, 5.1.1, 5.2.1
- [Describing use of required reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
- [Upcoming requirements](https://developer.apple.com/news/upcoming-requirements/)
- [App Store Connect: platform version information](https://developer.apple.com/help/app-store-connect/reference/platform-version-information) and [screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications)
- [Manage European Union Digital Services Act trader requirements](https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements)
