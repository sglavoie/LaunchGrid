import Foundation

public enum Search {
    /// Match score for `name` against `query`: prefix > word start > initials > substring >
    /// subsequence, whatever the name's length. Tiers don't overlap; length ranks within one.
    /// A query of several words also counts as a word start when each of its words starts
    /// a different word of the name, in any order ("word micro" finds "Microsoft Word"), and
    /// as initials when its words, in order, start words or spell their initials ("vs code").
    /// Separators other than spaces don't count towards a prefix, so "wifi" finds "Wi-Fi Explorer"
    /// and "visual-" finds "Visual Studio Code" as if typed without them, a little below a prefix
    /// as typed: "c++" is "c" that way, and "C++ Builder" must still come before "Chess". A space typed in the
    /// query may be skipped ("wi fi" finds "WiFiman"), but one in the name may not: "apps" isn't
    /// a prefix of "App Store".
    /// Returns nil when there is no match.
    public static func score(_ name: String, query: String) -> Int? {
        let q = normalize(query)
        // Separators alone ("-") would match every name that has one.
        guard q.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        let n = normalize(name)
        if n == q { return 1000 }
        if n.hasPrefix(q) { return 900 - shortness(n) }
        let isSeparator: (Character) -> Bool = { !$0.isLetter && !$0.isNumber }
        let words = n.split(whereSeparator: isSeparator).map(String.init)
        let queryWords = q.split(whereSeparator: isSeparator)
        let (nameKey, queryKey) = (spacedWords(n), spacedWords(q))
        if !queryKey.isEmpty, nameKey.hasPrefix(queryKey) || nameKey.hasPrefix(queryKey.filter { $0 != " " }) {
            return 850 - shortness(n)
        }
        if words.contains(where: { $0.hasPrefix(q) }) { return 700 - shortness(n) }
        if !queryWords.isEmpty, startsDistinctWords(queryWords, of: words) { return 700 - shortness(n) }
        // With the humps and without: "qp" is QuickTime Player's initials as much as "qtp" is.
        if acronym(of: name).hasPrefix(q) || acronym(of: name, humps: false).hasPrefix(q) { return 600 }
        if queryWords.count > 1, startsWordsOrInitials(queryWords, of: words) { return 600 }
        if n.contains(q) { return 500 - shortness(n) }
        // Two characters say more in a script without an alphabet ("网音" for 网易云音乐).
        // Counted as typed: one Hangul syllable is several letters in `q`.
        let minimum = query.contains(where: TextLine.isUnspaced) ? 2 : 3
        let typed = query.precomposedStringWithCanonicalMapping.filter { !$0.isWhitespace }.count
        if typed >= minimum, q.count >= minimum, isSubsequence(q, of: n) { return 200 - shortness(n) }
        return nil
    }

    /// What a longer name loses within a tier, kept under the 50 points between tiers so a long
    /// name doesn't fall into the tier below.
    private static func shortness(_ n: String) -> Int { min(n.count, 49) }

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

    /// `s` with separators other than spaces dropped and each run of spaces made one:
    /// "Wi-Fi  Explorer" → "wifi explorer".
    private static func spacedWords(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace)
            .map { $0.filter { $0.isLetter || $0.isNumber } }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func normalize(_ s: String) -> String {
        // Composed first: a name in decomposed form (from an HFS+ disk or a zip) keeps
        // conjoining Hangul letters that no typed query would equal.
        var s = s.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        // Letters the folding leaves alone, written as their plain-letter spelling.
        if s.unicodeScalars.contains(where: { letterSpellings[$0] != nil }) {
            s = String(String.UnicodeScalarView(s.unicodeScalars.flatMap { letterSpellings[$0].map { Array($0.unicodeScalars) } ?? [$0] }))
        }
        // Hangul syllables as their letters, so a syllable still being typed ("하") finds "한글".
        if s.unicodeScalars.contains(where: { hangulSyllables.contains($0.value) || letterParts[$0] != nil }) {
            s = String(String.UnicodeScalarView(s.unicodeScalars.flatMap(hangulLetters)))
        }
        // Hiragana as katakana, so "かめら" finds "カメラ".
        if s.unicodeScalars.contains(where: { (0x3041...0x3096).contains($0.value) }) {
            s = s.applyingTransform(.hiraganaToKatakana, reverse: false) ?? s
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static let hangulSyllables: ClosedRange<UInt32> = 0xAC00...0xD7A3

    /// A syllable's letters as compatibility jamo, which unlike the conjoining ones its
    /// canonical decomposition gives are characters of their own, so a prefix can end mid-syllable.
    /// Compound letters come apart, as they are typed: "고" is on the way to "과", "달" to "닭".
    private static func hangulLetters(_ scalar: Unicode.Scalar) -> [Unicode.Scalar] {
        guard hangulSyllables.contains(scalar.value) else { return letterParts[scalar] ?? [scalar] }
        let s = Int(scalar.value - hangulSyllables.lowerBound)
        let (lead, vowel, tail) = (s / 588, s % 588 / 28, s % 28)
        return ([leadLetters[lead], vowelLetters[vowel]] + (tail > 0 ? [tailLetters[tail - 1]] : []))
            .flatMap { letterParts[$0] ?? [$0] }
    }

    private static let leadLetters = Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ".unicodeScalars)
    private static let vowelLetters = Array("ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ".unicodeScalars)
    private static let tailLetters = Array("ㄱㄲㄳㄴㄵㄶㄷㄹㄺㄻㄼㄽㄾㄿㅀㅁㅂㅄㅅㅆㅇㅈㅊㅋㅌㅍㅎ".unicodeScalars)
    /// Letters typed as two keys. ㄲ, ㅆ, ㅐ and the like are one key each, so they stay whole.
    private static let letterParts: [Unicode.Scalar: [Unicode.Scalar]] = Dictionary(uniqueKeysWithValues: [
        "ㅘ": "ㅗㅏ", "ㅙ": "ㅗㅐ", "ㅚ": "ㅗㅣ", "ㅝ": "ㅜㅓ", "ㅞ": "ㅜㅔ", "ㅟ": "ㅜㅣ", "ㅢ": "ㅡㅣ",
        "ㄳ": "ㄱㅅ", "ㄵ": "ㄴㅈ", "ㄶ": "ㄴㅎ", "ㄺ": "ㄹㄱ", "ㄻ": "ㄹㅁ", "ㄼ": "ㄹㅂ", "ㄽ": "ㄹㅅ",
        "ㄾ": "ㄹㅌ", "ㄿ": "ㄹㅍ", "ㅀ": "ㄹㅎ", "ㅄ": "ㅂㅅ",
    ].map { (Unicode.Scalar($0.key)!, Array($0.value.unicodeScalars)) })

    /// After case folding, so lowercase only.
    private static let letterSpellings: [Unicode.Scalar: String] = [
        "æ": "ae", "œ": "oe", "ø": "o", "ł": "l", "đ": "d", "ð": "d", "þ": "th", "ı": "i",
    ]

    /// Initials of words and of camel-case humps: "Visual Studio Code" → "vsc", "GarageBand" → "gb",
    /// and after a run of capitals, "PDFExpert" → "pe". Without `humps`, words only: "QuickTime
    /// Player" → "qp". An apostrophe between letters stays inside the word: "Don't Sleep" → "ds".
    static func acronym(of name: String, humps: Bool = true) -> String {
        let chars = Array(name)
        var out = ""
        for (i, ch) in chars.enumerated() where ch.isLetter || ch.isNumber {
            let previous: Character = i > 0 ? chars[i - 1] : " "
            let next: Character = i + 1 < chars.count ? chars[i + 1] : " "
            let wordStart = i == 0 || !TextLine.isWord(chars, i - 1)
            let hump = humps && ch.isUppercase && (previous.isLowercase || (previous.isUppercase && next.isLowercase))
            if wordStart || hump { out.append(ch) }
        }
        return normalize(out)
    }

    /// Whether each query word starts a different word of the name, so "word word" doesn't
    /// find "Microsoft Word" through its one "Word".
    /// A matching of query words to name words, grown one query word at a time by moving
    /// earlier ones aside, so a long query of like words takes steps, not every assignment.
    static func startsDistinctWords(_ queryWords: [Substring], of words: [String]) -> Bool {
        guard queryWords.count <= words.count else { return false }
        // For each name word, the query word that starts it.
        var owner = [Int?](repeating: nil, count: words.count)
        func place(_ i: Int, _ seen: inout [Bool]) -> Bool {
            for (k, word) in words.enumerated() where !seen[k] && word.hasPrefix(queryWords[i]) {
                seen[k] = true
                if owner[k].map({ place($0, &seen) }) ?? true {
                    owner[k] = i
                    return true
                }
            }
            return false
        }
        return queryWords.indices.allSatisfy { i in
            var seen = [Bool](repeating: false, count: words.count)
            return place(i, &seen)
        }
    }

    /// Whether the query words, in order, each start a word of the name or spell the initials
    /// of a run of its words ("vs code" for "Visual Studio Code"); words in between may be skipped.
    static func startsWordsOrInitials(_ queryWords: [Substring], of words: [String]) -> Bool {
        // Positions already found not to match, so each is tried once.
        var failed = Set<[Int]>()
        func match(_ i: Int, _ j: Int) -> Bool {
            guard i < queryWords.count else { return true }
            guard j < words.count, !failed.contains([i, j]) else { return false }
            let w = queryWords[i]
            if words[j].hasPrefix(w), match(i + 1, j + 1) { return true }
            if w.count > 1, j + w.count <= words.count,
               zip(w, words[j...]).allSatisfy({ $0 == $1.first }), match(i + 1, j + w.count) { return true }
            if match(i, j + 1) { return true }
            failed.insert([i, j])
            return false
        }
        return match(0, 0)
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
