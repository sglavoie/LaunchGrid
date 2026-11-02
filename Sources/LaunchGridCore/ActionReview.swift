import Foundation

/// Grid files can be shared, and an action in one runs on Return. A file someone opens is
/// treated as untrusted: its actions are listed before it loads and need a look in the editor
/// before they run. The app's own layout, and its backups, are trusted and never pass here.
extension ActionKind {
    /// Whether running it does something beyond opening a web page, a file or a Shortcut: a
    /// command, a script, or a link to another app (`obsidian://`, `x-callback-url`, `file://`).
    public var isRunnableCode: Bool {
        switch self {
        case .shell, .userScript: true
        case .openURL(let template): !Self.isWebLink(template)
        case .openFile, .shortcut: false
        }
    }

    static func isWebLink(_ template: String) -> Bool {
        let t = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = t.firstIndex(of: ":") else { return false }
        let scheme = t[..<colon].lowercased()
        return scheme == "http" || scheme == "https"
    }

    /// What it does, in full, for the person to check: the command, script and arguments, link,
    /// file or Shortcut.
    public var reviewDescription: String {
        switch self {
        case .openURL(let template): return template
        case .openFile(let path, let appPath):
            return appPath.map { String(localized: "\(path) with \($0)") } ?? path
        case .shortcut(let name, let input):
            return input.map { String(localized: "Shortcut “\(name)” with input \($0)") } ?? String(localized: "Shortcut “\(name)”")
        case .shell(let command, _, let directory, _):
            return directory.map { String(localized: "\(command)\n(in \($0))") } ?? command
        case .userScript(let fileName, let arguments, _):
            return ([String(localized: "Script \(fileName)")] + arguments).joined(separator: "\n")
        }
    }
}

/// An action in a grid file being opened, for the review sheet.
public struct ActionReviewEntry: Equatable, Sendable, Identifiable {
    public var action: Action
    /// A command, script or non-web link: the sheet is shown because of these.
    public var isRunnableCode: Bool
    public var id: UUID { action.id }
    public var detail: String { action.kind.reviewDescription }
}

/// What to do with the actions of a grid file being loaded.
public enum ActionReviewChoice: Sendable {
    /// Keep them all, each needing review before it runs.
    case keepForReview
    /// Leave out the commands, scripts and non-web links; the rest are kept for review.
    case removeRunnable
}

extension Grid {
    /// Every action in the layout, in search order, with whether it is a reason to ask.
    public var actionReview: [ActionReviewEntry] {
        allActions.map { ActionReviewEntry(action: $0, isRunnableCode: $0.kind.isRunnableCode) }
    }

    /// Whether loading it has to ask first: it holds a command, script or non-web link.
    public var needsActionReview: Bool { allActions.contains { $0.kind.isRunnableCode } }

    /// The layout as a loaded grid file goes in: every action kept needs review.
    public func applyingReview(_ choice: ActionReviewChoice) -> Grid {
        var grid = self
        if choice == .removeRunnable {
            grid.remove(allActions.filter { $0.kind.isRunnableCode }.map(\.id))
        }
        grid.mapActions { $0.needsReview = true }
        return grid
    }

    /// Whether some action holds a command or a script, which a saved grid file leaves out
    /// unless asked.
    public var hasCommands: Bool {
        allActions.contains {
            switch $0.kind {
            case .shell, .userScript: true
            default: false
            }
        }
    }

    /// The layout to save in a grid file without its commands and scripts: each becomes a
    /// placeholder with its name, keywords and icon, which needs review, so the layout keeps
    /// its shape and nothing of the command is written.
    public func removingCommands() -> Grid {
        var grid = self
        grid.mapActions { action in
            switch action.kind {
            case .shell(_, let mode, _, _):
                action.kind = .shell(command: "", runMode: mode, workingDirectory: nil, timeoutSeconds: nil)
            case .userScript(_, _, let mode):
                action.kind = .userScript(fileName: "", arguments: [], runMode: mode)
            default:
                return
            }
            action.needsReview = true
        }
        return grid
    }

    /// Changes every action, on pages and search-only, in place.
    mutating func mapActions(_ change: (inout Action) -> Void) {
        for p in pages.indices {
            for i in pages[p].items.indices {
                guard case .action(var a) = pages[p].items[i] else { continue }
                change(&a)
                pages[p].items[i] = .action(a)
            }
        }
        for k in hiddenActions.indices { change(&hiddenActions[k]) }
    }
}
