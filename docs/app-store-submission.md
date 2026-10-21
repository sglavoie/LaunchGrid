# Mac App Store submission

**October 21, 2026.** What Apple requires before LaunchGrid can be accepted on the Mac App Store, what is already done, and what is left. Apple's rules change: re-read the [sources](#sources) before submitting.

## Summary

- **The website is ready.** `website/` holds the home page, privacy policy and support page for `launchgrid.sglavoie.com`. They go live with `just website-deploy`.
- **One blocker remains: the App Sandbox.** Guideline 2.4.5(i) requires every Mac App Store app to be sandboxed, and LaunchGrid deliberately isn't. Several features need changes to work inside it (see [Sandbox](#1-app-sandbox)).
- **The repository must be public before submission.** The support page sends people to GitHub issues, and a private repository shows reviewers a 404.
- The rest is App Store Connect paperwork and packaging.

## URLs for App Store Connect

| Field | URL | Required |
| --- | --- | --- |
| Privacy Policy URL | `https://launchgrid.sglavoie.com/privacy/` | Yes, for every app (5.1.1(i)) |
| Support URL | `https://launchgrid.sglavoie.com/support/` | Yes; must lead to real contact information (1.5) |
| Marketing URL | `https://launchgrid.sglavoie.com/` | No |

Guideline 2.1(a) rejects "empty websites and other temporary content", so deploy the site before entering these. Once the app is approved, replace "Coming to the Mac App Store" on the home page (hero and "Get LaunchGrid") with the App Store link, using Apple's official badge from the [marketing resources](https://developer.apple.com/app-store/marketing/guidelines/).

## Done in this change

| Requirement | Change |
| --- | --- |
| Privacy policy linked **inside the app** (5.1.1(i)) and an easy way to contact the developer (1.5) | "LaunchGrid Support" and "Privacy Policy" in the menu-bar icon's menu and the app menu (`AppDelegate.swift`) |
| Export compliance | `ITSAppUsesNonExemptEncryption = false` in `scripts/bundle.sh`. LaunchGrid uses no encryption, so App Store Connect stops asking at each upload |
| Copyright | `NSHumanReadableCopyright` was "Free and open. No paywall."; it is now "© 2026 Sébastien Lavoie" |

## What is left in the app

### 1. App Sandbox

Required by 2.4.5(i). Add `com.apple.security.app-sandbox` and, for the panels LaunchGrid already uses, `com.apple.security.files.user-selected.read-write` and `com.apple.security.files.bookmarks.app-scope`. Then each of these needs work:

| Feature | Inside the sandbox | What to change |
| --- | --- | --- |
| Scanning `/Applications` and `/System/Applications` | Readable; FSEvents works | Nothing |
| Scanning `~/Applications` (`AppScanner.defaultRoots`) | `homeDirectoryForCurrentUser` returns the container, so the folder is silently skipped | Get the real home from `getpwuid(getuid())`, and either ask for the folder once with `NSOpenPanel` (security-scoped bookmark) or request the `temporary-exception.files.home-relative-path.read-only` entitlement for `/Applications/` and justify it in the review notes |
| Extra scan folders (`Preferences.scanRoots`) | Stored as paths, so unreadable after relaunch | Store security-scoped bookmarks from the panel; start access before scanning and watching |
| Custom background picture (`customImagePath`) | Same | Same |
| Wallpaper background (`desktopImageURL`) | Pictures outside readable locations fail to load | Already falls back to the blurred desktop; acceptable, or offer to pick the picture |
| Launchpad import (`launchpadDatabaseURL`) | `/private/var/folders/…/com.apple.dock.launchpad` is outside the sandbox; the `fileExists` check fails, so the option disappears | Open an `NSOpenPanel` at that folder and import what the person picks |
| AppGrid import (`appGridDatabaseURL`) | Another app's container: blocked by the sandbox and by macOS app data protection | Import only files the person picks (`.agrid` exports), or drop the menu item |
| Layout and settings | Move into `~/Library/Containers/com.sglavoie.launchgrid` | Nothing for new users. Copies built from source today don't migrate; fine, since none were distributed |
| Launching, Show in Finder, `.appgrid` files opened from Finder, Carbon hotkey, `SMAppService` | Work | Nothing. Open at Login is off until the person turns it on, which satisfies 2.4.5(iii) |

The privacy and support pages already name the container path for the App Store version, and describe the Launchpad import as "if your Mac still has the database". If the AppGrid import is dropped, nothing on the site changes; if `~/Applications` stops being scanned by default, update "the applications in your Applications folders" in the privacy policy.

### 2. Privacy manifest

Add `Contents/Resources/PrivacyInfo.xcprivacy` with `NSPrivacyTracking` false, no tracking domains, no collected data types, and the APIs below. Apple's wording requires it for apps that use these APIs; whether App Store Connect enforces it for Mac apps is unclear, and adding it costs nothing.

| API category | Where | Reason |
| --- | --- | --- |
| User defaults | `Preferences.swift`, `Services.swift` | `CA92.1` (the app's own defaults) |
| File timestamps | `AppDelegate.isScratch` (`creationDate` of a marker in the app's temp folder) | `C617.1` (files in the app's container) |
| File timestamps | `IconProvider` in `Services.swift` (`modificationDate` of other apps' `Info.plist`) | No approved reason fits well. Simplest fix: key the cache on `CFBundleVersion` and `CFBundleShortVersionString` instead of the date |
| System boot time | `DebugScript.swift` (`systemUptime`) | `35F9.1`, or compile `DebugScript` out of release builds with `#if DEBUG`, which also keeps the synthetic-event hooks out of the shipped app |

### 3. Packaging and signing

2.4.5(ii) requires packaging "using technologies provided in Xcode". `codesign`, `productbuild` and `altool` are Xcode tools, so `scripts/bundle.sh` can stay, with a Mac App Store mode that:

1. Builds universal (`swift build -c release --arch arm64 --arch x86_64`). Not required, but Intel Macs still run macOS 14 through 26.
2. Copies the Mac App Store provisioning profile to `Contents/embedded.provisionprofile`.
3. Signs with the **Apple Distribution** certificate and an entitlements file holding the sandbox keys plus `com.apple.application-identifier` (`TEAMID.com.sglavoie.launchgrid`) and `com.apple.developer.team-identifier`.
4. Wraps the app with `productbuild --component build/LaunchGrid.app /Applications --sign "3rd Party Mac Developer Installer: …" LaunchGrid.pkg`.
5. Uploads with `xcrun altool --upload-package` or the Transporter app.

`CFBundleVersion` is the commit count, which rises with each commit, as App Store Connect requires. The icon set already includes the 1024 px (`512@2x`) size.

### 4. Names, trademarks and the AppGrid origin

- **4.1 (copycats) and 5.2.1 (intellectual property).** The README says LaunchGrid was "rebuilt from the observed behaviour of AppGrid" with "every former Pro feature" free. AppGrid is a paid Mac App Store app. A reviewer or AppGrid's developer reading that could see a copy. Before the repository goes public, rewrite those lines, and the "Deliberately left out" section that names RevenueCat and the paywall, to describe LaunchGrid on its own terms. The name, icon and interface are already distinct.
- **2.3.7 (metadata).** Keep "Launchpad" and "AppGrid" out of the name, subtitle and keywords. The description may say factually that it can import an older Launchpad layout. "Launchpad" is Apple's trademark; Apple's [trademark guidelines](https://www.apple.com/legal/intellectual-property/guidelinesfor3rdparties.html) allow referring to it in plain text, not as part of your product's branding.
- **Name availability.** App Store Connect rejects a name another developer already uses; reserve "LaunchGrid" when creating the app record.

### 5. Open-sourcing

- Make `sglavoie/LaunchGrid` public, with a licence, before submitting, so the support page's issue links work. MIT or Apache 2.0 avoids the long-running questions about the GPL and the App Store's terms.
- Reviewers sometimes reject support pages whose only contact needs an account. If that happens, add an email address (for example a Cloudflare Email Routing alias) to the support page's summary box.

## App Store Connect

| Item | Answer or note |
| --- | --- |
| Membership | Paid Apple Developer Program (99 USD a year) |
| Price | Free; no Paid Apps agreement needed |
| Category | Utilities (matches `LSApplicationCategoryType`); Productivity as secondary |
| Name and subtitle | 30 characters each. For example, "LaunchGrid" and "Full-screen app grid and search" |
| Keywords | 100 characters, no trademarks: app launcher, grid, folders, apps, shortcut, keyboard, organize… |
| Screenshots | 1 to 10, 16:10, at 1280×800, 1440×900, 2560×1600 or 2880×1800; showing the app in use (2.3.3), not the welcome window alone |
| App Privacy | Data Not Collected |
| Age rating | Answer the questionnaire; every answer is "none", which gives the lowest rating |
| EU trader status | Required to be available in the EU under the Digital Services Act. A trader has the address, phone and email given to Apple shown on the product page in the EU. A free hobby app may qualify as non-trader; leaving out the EU is the other option |
| Review contact | Name, email and a phone number in international format; not shown publicly |
| Review notes | LaunchGrid lives in the menu bar (`LSUIElement`). ⌥Space shows the grid; right-click the menu-bar icon for Settings. The welcome window appears on first launch. Explain any temporary-exception entitlement from [Sandbox](#1-app-sandbox) |
| Copyright | 2026 Sébastien Lavoie |
| AI disclosure | Not required by the guidelines for AI-written code; they cover AI only where an app shares personal data with a third-party AI (5.1.2(i)), which LaunchGrid doesn't. To match the website, end the description with: "About 99% of LaunchGrid was written with AI (Claude, by Anthropic). The app contains no AI features and makes no network connections." Keep it out of the name, subtitle and keywords (2.3.7) |

## Sources

Read on October 21, 2026:

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/): 1.5, 2.1, 2.3.7, 2.4.5, 4.1, 5.1.1, 5.2.1
- [Describing use of required reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
- [Upcoming requirements](https://developer.apple.com/news/upcoming-requirements/)
- [App Store Connect: platform version information](https://developer.apple.com/help/app-store-connect/reference/platform-version-information) and [screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications)
- [Manage European Union Digital Services Act trader requirements](https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements)
