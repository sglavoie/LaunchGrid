import Foundation

public enum Search {
    /// Match score for `name` against `query`: prefix > word start > initials > substring >
    /// subsequence, whatever the name's length. Tiers don't overlap; length ranks within one.
    /// A query of several words also counts as a word start when each of its words starts
    /// a word of the name, in any order ("word micro" finds "Microsoft Word").
    /// Returns nil when there is no match.
    public static func score(_ name: String, query: String) -> Int? {
        let q = normalize(query)
        guard !q.isEmpty else { return nil }
        let n = normalize(name)
        if n == q { return 1000 }
        if n.hasPrefix(q) { return 900 - min(n.count, 99) }
        let isSeparator: (Character) -> Bool = { !$0.isLetter && !$0.isNumber }
        let words = n.split(whereSeparator: isSeparator).map(String.init)
        if words.contains(where: { $0.hasPrefix(q) }) { return 700 - min(n.count, 99) }
        let queryWords = q.split(whereSeparator: isSeparator)
        if queryWords.count > 1, queryWords.allSatisfy({ qw in words.contains { $0.hasPrefix(qw) } }) {
            return 700 - min(n.count, 99)
        }
        if acronym(of: name).hasPrefix(q) { return 600 }
        if n.contains(q) { return 500 - min(n.count, 99) }
        if q.count >= 3, isSubsequence(q, of: n) { return 200 - min(n.count, 99) }
        return nil
    }

    /// Apps matching `query`, best first, ties broken alphabetically.
    public static func results(in apps: [AppRef], query: String) -> [AppRef] {
        apps.compactMap { app -> (AppRef, Int)? in
            let s = [score(app.title, query: query), app.displayName == nil ? nil : score(app.name, query: query)]
                .compactMap { $0 }.max()
            return s.map { (app, $0) }
        }
        .sorted { a, b in
            a.1 != b.1 ? a.1 > b.1 : a.0.title.localizedStandardCompare(b.0.title) == .orderedAscending
        }
        .map(\.0)
    }

    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Initials of words and of camel-case humps: "Visual Studio Code" → "vsc", "GarageBand" → "gb".
    static func acronym(of name: String) -> String {
        var out = ""
        var previous: Character = " "
        for ch in name {
            if ch.isLetter || ch.isNumber {
                if !(previous.isLetter || previous.isNumber) || (ch.isUppercase && previous.isLowercase) {
                    out.append(ch)
                }
            }
            previous = ch
        }
        return normalize(out)
    }

    static func isSubsequence(_ q: String, of s: String) -> Bool {
        var i = s.startIndex
        for ch in q {
            guard let found = s[i...].firstIndex(of: ch) else { return false }
            i = s.index(after: found)
        }
        return true
    }
}
