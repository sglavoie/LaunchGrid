import Foundation

public struct ReconcileReport: Equatable, Sendable {
    public var added: [String] = []
    public var removed: [String] = []
    public var moved: [String] = []
    public var duplicatesDropped = 0

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && moved.isEmpty && duplicatesDropped == 0 }
}

/// Merges the installed-app catalog into a grid.
public enum Reconciler {
    /// - Parameters:
    ///   - autoAdd: append installed apps that are neither on the grid nor in `removedBundleIDs`.
    ///   - pruneMissing: drop apps that are no longer installed. Callers disable this when the
    ///     scan looks unreliable (e.g. it found nothing at all).
    public static func reconcile(
        _ grid: inout Grid,
        installed: [InstalledApp],
        autoAdd: Bool,
        pruneMissing: Bool = true
    ) -> ReconcileReport {
        var report = ReconcileReport()
        let byPath = Dictionary(installed.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let byBundle = Dictionary(installed.compactMap { app in app.bundleID.map { ($0, app) } },
                                  uniquingKeysWith: { a, _ in a })
        // Never prune when the scan came back empty: that's a failed scan, not an empty Mac.
        let prune = pruneMissing && !installed.isEmpty
        var seen = Set<String>()

        /// Returns the refreshed ref, or nil when it should leave the grid.
        func refresh(_ ref: AppRef) -> AppRef? {
            var ref = ref
            if let match = byPath[ref.path], ref.bundleID == nil || match.bundleID == ref.bundleID {
                ref.name = match.name
                if ref.bundleID == nil { ref.bundleID = match.bundleID }
            } else if let id = ref.bundleID, let match = byBundle[id] {
                report.moved.append(match.name)
                ref.path = match.path
                ref.name = match.name
            } else if prune {
                report.removed.append(ref.title)
                return nil
            }
            guard seen.insert(ref.key).inserted else {
                report.duplicatesDropped += 1
                return nil
            }
            return ref
        }

        for p in grid.pages.indices {
            grid.pages[p].items = grid.pages[p].items.compactMap { item in
                switch item {
                case .app(let a):
                    return refresh(a).map(GridItem.app)
                case .folder(var f):
                    f.apps = f.apps.compactMap(refresh)
                    return f.apps.isEmpty ? nil : .folder(f)
                }
            }
        }

        if autoAdd {
            let fresh = installed
                .filter { !seen.contains($0.key) && !grid.removedBundleIDs.contains($0.key) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            var keys = seen
            let unique = fresh.filter { keys.insert($0.key).inserted }
            grid.appendToFirstFree(unique.map { .app($0.makeRef()) })
            report.added = unique.map(\.name)
        }

        grid.normalize()
        return report
    }

    /// Installed apps that are not on the grid, for "Add Missing Apps…".
    public static func missingApps(in grid: Grid, installed: [InstalledApp]) -> [InstalledApp] {
        let keys = grid.appKeys
        let paths = Set(grid.allApps.map(\.path))
        return installed
            .filter { !keys.contains($0.key) && !paths.contains($0.path) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Adds apps explicitly, clearing them from the removed list.
    public static func add(_ apps: [InstalledApp], to grid: inout Grid) {
        let keys = grid.appKeys
        let new = apps.filter { !keys.contains($0.key) }
        for app in apps { grid.removedBundleIDs.remove(app.key) }
        grid.appendToFirstFree(new.map { .app($0.makeRef()) })
    }
}
