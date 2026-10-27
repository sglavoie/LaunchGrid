import Foundation
import UniformTypeIdentifiers

/// Finds application bundles on disk.
public enum AppScanner {
    public static var defaultRoots: [URL] {
        // ~/Applications is readable in the sandbox through a temporary-exception entitlement.
        let home = Sandbox.realHome
        var paths = [
            "/Applications",
            "/System/Applications",
            home.appendingPathComponent("Applications").path,
        ]
        // The sandbox can't read Homebrew's folders; /opt/homebrew can still be added under Extra folders.
        if !Sandbox.isActive { paths += homebrewRoots }
        return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Homebrew's `opt` folders (Apple silicon, then Intel), where a formula that installs an
    /// app keeps it: `opt/python@3.14/IDLE 3.app`. Casks put theirs in /Applications.
    public static let homebrewRoots = ["/opt/homebrew/opt", "/usr/local/opt"]

    /// Whether `dir` is a Homebrew `opt` folder: named `opt`, next to the `Cellar` its links
    /// lead into.
    static func isHomebrewOpt(_ dir: URL) -> Bool {
        dir.lastPathComponent == "opt"
            && FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().appendingPathComponent("Cellar").path)
    }

    /// In a Homebrew `opt` folder, a link named after another formula is an alias of it
    /// (`python3` and `python@3` lead to `Cellar/python@3.15/…`). Its apps are found through
    /// the formula's own link, whose path stays put when the alias moves to a newer version.
    static func isHomebrewAlias(_ link: URL, target: URL) -> Bool {
        target.deletingLastPathComponent().lastPathComponent != link.lastPathComponent
    }

    /// Scans the roots (recursing into plain folders up to `maxDepth`, never into bundles)
    /// and returns one entry per app bundle on disk, de-duplicated by resolved path with
    /// earlier roots winning. Copies sharing a bundle ID (Xcode and Xcode-beta) are all kept.
    /// Apps flagged `LSDefaultSystemHidden` (e.g. the two bundles both named Siri) are left
    /// out, as macOS leaves them out of its own app list; they can still be added by hand.
    public static func scan(roots: [URL], maxDepth: Int = 3) -> [InstalledApp] {
        scanReporting(roots: roots, maxDepth: maxDepth).apps
    }

    /// What a scan found, and the folders it couldn't list.
    public struct ScanResult: Sendable {
        public var apps: [InstalledApp]
        /// Folders (roots included) that couldn't be listed: missing, denied by privacy
        /// controls, a stalled network volume or a lapsed sandbox bookmark. Their apps went
        /// unseen, which says nothing about whether they are still there.
        public var unlisted: [String]
        /// Real paths and alternate app symlinks, each mapped to the path the scan lists the
        /// app at: /System/Cryptexes/…/Safari.app to /Applications/Safari.app. An open panel
        /// or saved layout can use either, so this tells it is an app already found.
        public var aliases: [String: String]

        public init(apps: [InstalledApp], unlisted: [String] = [], aliases: [String: String] = [:]) {
            self.apps = apps
            self.unlisted = unlisted
            self.aliases = aliases
        }
    }

    /// `scan(roots:maxDepth:)`, also reporting the folders it couldn't list.
    public static func scanReporting(roots: [URL], maxDepth: Int = 3) -> ScanResult {
        let fm = FileManager.default
        // Largest remaining depth each directory was walked with. Roots can have different
        // limits (Homebrew's automatic scan is shallower), so depth alone isn't enough.
        var visited: [String: Int] = [:]
        var results: [InstalledApp] = []
        var paths: [String: String] = [:]
        var unlisted: [String] = []
        var aliases: [String: String] = [:]
        var directoryAliases: [String: String] = [:]
        var directoryBundles: [String: [String: String]] = [:]
        var directoryChildren: [String: [String: String]] = [:]

        /// `realPath` is the bundle's symlink-free path, its identity for de-duplication.
        func consider(_ url: URL, realPath: String) {
            if let listed = paths[realPath] {
                if url.path != listed { aliases[url.path] = listed }
                return
            }
            guard let info = infoDictionary(ofBundleAt: url),
                  info["LSDefaultSystemHidden"] as? Bool != true else { return }
            paths[realPath] = url.path
            results.append(read(appAt: url, info: info))
            if realPath != url.path { aliases[realPath] = url.path }
        }

        /// `limit` is the depth walked to. In a Homebrew `opt` folder, aliases are skipped.
        func walk(_ dir: URL, depth: Int, limit: Int, homebrewOpt: Bool = false) {
            let real = dir.resolvingSymlinksInPath().path
            // Even a directory already walked can give saved tiles another spelling of its
            // apps. Remember it before the cycle/repeat guard, without walking it again.
            directoryAliases[dir.path] = real
            directoryAliases[real] = real
            let remaining = max(0, limit - depth)
            if let seen = visited[real], seen >= remaining { return } // symlink cycle or repeat
            visited[real] = remaining
            // Listing doesn't follow a symlink to a folder (/opt/homebrew/opt/python@3.14): its
            // target is listed, and what's in it keeps the path through the link.
            let linked = real != dir.path
            guard let children = try? fm.contentsOfDirectory(at: linked ? URL(fileURLWithPath: real, isDirectory: true) : dir,
                                                             includingPropertiesForKeys: Array(scanKeys)) else {
                unlisted.append(dir.path)
                return
            }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if child.lastPathComponent.hasPrefix(".") { continue }
                // Answered from the values prefetched with the listing. Only a symlink is
                // resolved, to ask about its target (e.g. Safari's).
                guard let own = try? child.resourceValues(forKeys: scanKeys) else { continue }
                let target = own.isSymbolicLink == true ? child.resolvingSymlinksInPath() : nil
                guard let v = target.map({ try? $0.resourceValues(forKeys: scanKeys) }) ?? own else { continue }
                // Keep the scan root's spelling even when the listing canonicalizes a parent
                // (e.g. /var to /private/var), so saved paths and alternate links still match.
                let path = dir.appendingPathComponent(child.lastPathComponent)
                if homebrewOpt, let target, isHomebrewAlias(child, target: target) {
                    // Don't scan through a moving formula alias, but recognize apps saved or
                    // picked through it as the same apps found through the formula's own link.
                    if v.isDirectory == true { directoryAliases[path.path] = target.path }
                    continue
                }
                // Apps flagged hidden still count: /Applications/Safari.app is a hidden symlink.
                if child.pathExtension.lowercased() == "app", v.contentType?.conforms(to: .applicationBundle) == true {
                    let inDirectory = (real as NSString).appendingPathComponent(child.lastPathComponent)
                    let realPath = target?.path ?? inDirectory
                    consider(path, realPath: realPath)
                    // Keep the app's name inside this directory even when the app itself is
                    // a link to somewhere else; directory aliases must cover that spelling too.
                    if let listed = paths[realPath] {
                        directoryBundles[real, default: [:]][child.lastPathComponent] = listed
                        if inDirectory != listed { aliases[inDirectory] = listed }
                    }
                } else if depth < limit, own.isHidden != true, v.isDirectory == true, v.isPackage != true {
                    directoryChildren[real, default: [:]][child.lastPathComponent] = target?.path
                        ?? (real as NSString).appendingPathComponent(child.lastPathComponent)
                    walk(path, depth: depth + 1, limit: limit)
                }
            }
        }

        for root in roots {
            // A formula installs its app at the top of its keg; its bin, lib and share hold none.
            let homebrewOpt = isHomebrewOpt(root)
            walk(root, depth: 1, limit: homebrewOpt ? min(maxDepth, 2) : maxDepth, homebrewOpt: homebrewOpt)
        }
        // Replay the directories already read for each spelling. A nested directory link
        // can lead outside its parent's real path, so a prefix match on bundle paths misses
        // it. Following the recorded edges needs no more disk reads; the ancestor set stops
        // cycles without hiding a sibling link to the same directory.
        func recordAliases(at directory: String, real: String, ancestors: Set<String>) {
            guard !ancestors.contains(real) else { return }
            var ancestors = ancestors
            ancestors.insert(real)
            for (name, listed) in directoryBundles[real] ?? [:] {
                let alternate = (directory as NSString).appendingPathComponent(name)
                if alternate != listed { aliases[alternate] = listed }
            }
            for (name, child) in directoryChildren[real] ?? [:] {
                recordAliases(at: (directory as NSString).appendingPathComponent(name), real: child, ancestors: ancestors)
            }
        }
        for (directory, real) in directoryAliases {
            recordAliases(at: directory, real: real, ancestors: [])
        }
        return ScanResult(apps: results, unlisted: unlisted, aliases: aliases)
    }

    static let scanKeys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentTypeKey, .isPackageKey, .isHiddenKey]

    /// A bundle's Info.plist, read from disk every time: `Bundle` caches it per path for the
    /// life of the process, so a rescan would miss an updated bundle ID or category.
    static func infoDictionary(ofBundleAt url: URL) -> [String: Any]? {
        let real = url.resolvingSymlinksInPath()
        if let info = NSDictionary(contentsOf: real.appendingPathComponent("Contents/Info.plist")) as? [String: Any] {
            return info
        }
        // Odd layouts (e.g. Info.plist at the bundle's root) are left to Bundle.
        return Bundle(url: real)?.infoDictionary.flatMap { $0.isEmpty ? nil : $0 }
    }

    public static func read(appAt url: URL) -> InstalledApp? {
        // Not an app without an Info.plist (e.g. a half-copied bundle or a stray folder).
        guard let info = infoDictionary(ofBundleAt: url) else { return nil }
        return read(appAt: url, info: info)
    }

    static func read(appAt url: URL, info: [String: Any]) -> InstalledApp {
        let path = url.path
        let bundleID = info["CFBundleIdentifier"] as? String
        var name = FileManager.default.displayName(atPath: path)
        if name.lowercased().hasSuffix(".app") { name = String(name.dropLast(4)) }
        // Finder can append a lowercase extension to an uppercase bundle filename:
        // "Shouting.APP.app". Strip the remaining filename extension only when this is
        // still the exact filename, preserving a real name such as "Notes.app".
        if name == url.lastPathComponent { name = AppRef.defaultName(forPath: path) }
        let category = info["LSApplicationCategoryType"] as? String
        return InstalledApp(bundleID: bundleID, path: path, name: name, category: category)
    }
}
