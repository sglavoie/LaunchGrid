# Mac App Store submission

**October 21, 2026.** What Apple requires before LaunchGrid can be accepted on the Mac App Store, what is already done, and what is left. Apple's rules change: re-read the [sources](#sources) before submitting.

## Summary

- **The website is ready.** `website/` holds the home page, privacy policy and support page for `launchgrid.sglavoie.com`.
- **The app is ready to be sandboxed.** `just app-store` builds the sandboxed, signed package (see [What's done in the app](#whats-done-in-the-app)). It needs a Mac App Store certificate pair and provisioning profile first, and the sandboxed build needs a manual test pass.
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

Checked: a sandboxed build (`SANDBOX=1 scripts/bundle.sh`) finds the same 128 apps as the unsandboxed one, including the five in `~/Applications`. Tested by hand in a sandboxed build (October 24, 2026): an app added from `~/Downloads` with Browse keeps its bookmark across relaunches, and follows the app when it moves, also after it left the grid meanwhile and when it was picked again at its new place, and while LaunchGrid runs (the next scan follows its bookmark). A copy of a database with its write-ahead log, loaded with Load Grid File…, asks for its folder through the Allow panel and imports what the log holds. **Still to test by hand with `just sandbox --keep`** (quit the installed copy first; without `--keep`, each run starts from an empty container): add an extra folder and a custom picture, relaunch and check they still work; import from AppGrid and from Launchpad (on a Mac that still has one) through the Allow panel; save and load a grid file; Open at Login.

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

- Create the **Apple Distribution** and **Mac Installer Distribution** certificates and install them. The keychain has only Apple Development and Developer ID Application ones today.
- Register the explicit App ID `com.sglavoie.launchgrid` (no capabilities needed).
- Create a **Mac App Store Connect** provisioning profile for it and save it as `private/LaunchGrid.provisionprofile`, which git ignores (or set `PROVISIONING_PROFILE`).

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
| Review notes | LaunchGrid lives in the menu bar (`LSUIElement`). ⌥Space shows the grid; right-click the menu-bar icon for Settings. The welcome window appears on first launch. For the entitlement: "LaunchGrid is an app launcher. It reads ~/Applications (read-only, through com.apple.security.temporary-exception.files.home-relative-path.read-only) because macOS and browsers install apps there, such as Chrome and Safari web apps, and a launcher that left them out would be incomplete. It only lists the app bundles there and reads their names, icons and Info.plist; it writes nothing." |
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
