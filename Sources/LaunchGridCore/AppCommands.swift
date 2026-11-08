import Foundation

/// Something LaunchGrid itself does that search can find, as it finds System Settings panes:
/// "shortcuts" or "keys" offers the Keyboard Shortcuts panel. In no layout: choosing it goes
/// through `AppCommand.command(for:)`, never the grid.
public enum AppCommand: String, CaseIterable, Sendable {
    case keyboardShortcuts

    /// Its name, as shown on its tile.
    public var name: String {
        switch self {
        case .keyboardShortcuts: String(localized: "Keyboard Shortcuts")
        }
    }

    /// Other words for it, searched as its name is.
    public var keywords: [String] {
        switch self {
        case .keyboardShortcuts: ["Shortcuts", "Keys", "Hotkeys", "Key Bindings", "Cheat Sheet", "Help"]
        }
    }

    public var symbol: String {
        switch self {
        case .keyboardShortcuts: "keyboard"
        }
    }

    /// A steady ID for it as a search result, the same from launch to launch.
    public var uuid: UUID { SettingsPane.uuid(for: "launchgrid-command:" + rawValue) }

    /// It as a search-only action, which the grid's views know how to show.
    public var action: Action {
        Action(id: uuid, name: name, keywords: [], icon: .symbol(symbol),
               kind: .openURL(template: ""), showsOnGrid: false)
    }

    /// The command a search result's ID stands for, if it is one.
    public static func command(for uuid: UUID) -> AppCommand? { byUUID[uuid] }

    private static let byUUID: [UUID: AppCommand] = Dictionary(uniqueKeysWithValues: allCases.map { ($0.uuid, $0) })

    /// The commands matching `query`: a name or other word it starts, or starts a word of,
    /// never a letter here and there. Nothing for fewer than three letters, so they don't
    /// crowd out apps while typing.
    public static func matches(_ query: String) -> [AppCommand] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 3 else { return [] }
        return allCases.filter { command in
            ([command.name] + command.keywords).contains { (Search.score($0, query: q) ?? 0) >= 625 }
        }
    }
}
