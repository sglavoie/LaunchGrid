import Foundation

public enum AppCategory {
    /// Friendly names for `LSApplicationCategoryType` values, grouped into broad pages.
    static let names: [String: String] = [
        "business": "Productivity",
        "productivity": "Productivity",
        "finance": "Productivity",
        "developer-tools": "Developer Tools",
        "utilities": "Utilities",
        "graphics-design": "Creativity",
        "photography": "Creativity",
        "video": "Creativity",
        "music": "Creativity",
        "entertainment": "Entertainment",
        "games": "Games",
        "social-networking": "Social",
        "news": "Information",
        "reference": "Information",
        "weather": "Information",
        "travel": "Information",
        "education": "Education",
        "lifestyle": "Lifestyle",
        "healthcare-fitness": "Lifestyle",
        "medical": "Lifestyle",
        "sports": "Lifestyle",
    ]

    public static let other = "Other"

    public static func name(for uti: String?) -> String {
        guard let uti else { return other }
        var key = uti.replacingOccurrences(of: "public.app-category.", with: "")
        if names[key] == nil, key.hasSuffix("-games") { key = "games" }
        return names[key] ?? other
    }
}

public enum BuildStyle: String, CaseIterable, Codable, Sendable {
    /// One or more pages per category, titled after it ("Pages as categories").
    case byCategory
    /// Everything alphabetical.
    case alphabetical
}

public enum GridBuilder {
    public static func build(from apps: [InstalledApp], style: BuildStyle, rows: Int, columns: Int) -> Grid {
        var grid = Grid(rows: rows, columns: columns)
        let sorted = apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        switch style {
        case .alphabetical:
            grid.pages = []
            grid.appendToFirstFree(sorted.map { .app($0.makeRef()) })
        case .byCategory:
            let groups = Dictionary(grouping: sorted) { AppCategory.name(for: $0.category) }
            let order = groups.keys.sorted { a, b in
                if a == AppCategory.other { return false }
                if b == AppCategory.other { return true }
                return a.localizedStandardCompare(b) == .orderedAscending
            }
            grid.pages = order.flatMap { title in
                let items = groups[title]!.map { GridItem.app($0.makeRef()) }
                return stride(from: 0, to: items.count, by: grid.capacity).map {
                    Page(title: title, items: Array(items[$0..<min($0 + grid.capacity, items.count)]))
                }
            }
        }
        grid.normalize()
        return grid
    }

    /// Suggested name for a folder made by dropping one app onto another.
    public static func folderName(for apps: [InstalledApp?]) -> String {
        let names = Set(apps.map { AppCategory.name(for: $0?.category) })
        if names.count == 1, let only = names.first, only != AppCategory.other { return only }
        return "New Folder"
    }
}
