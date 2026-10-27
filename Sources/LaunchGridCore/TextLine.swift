/// A single line of text with a caret, edited the way a macOS text field is from the keyboard.
/// `caret` counts characters from the start.
public struct TextLine: Equatable, Sendable {
    public private(set) var text: String
    public private(set) var caret: Int

    public init(text: String = "", caret: Int? = nil) {
        self.text = text
        self.caret = max(0, min(caret ?? text.count, text.count))
    }

    public var beforeCaret: Substring { text.prefix(caret) }
    public var afterCaret: Substring { text.dropFirst(caret) }

    public mutating func insert(_ s: String) {
        // Counted after joining: a combining accent or the second half of a flag merges with
        // the character before it.
        let head = String(beforeCaret) + s
        let joined = head + afterCaret
        // Typing never changes the characters after the caret: an insertion that would fuse
        // with them (a lone regional indicator before a flag, which would pair it off with
        // the flag's first half and break every flag after it) is dropped.
        guard joined.suffix(afterCaret.count).elementsEqual(afterCaret) else { return }
        text = joined
        caret = min(head.count, text.count)
    }

    /// `s` as one line, for pasting: each run of whitespace and line breaks (`\r\n`, tabs
    /// included) becomes one space, other control characters go, and the ends are trimmed.
    /// So do invisible format characters standing alone (a zero-width space, or a direction
    /// override that would show the name reversed); a joiner inside an emoji or a word stays.
    public static func singleLine(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map { $0.filter { c in
                !c.unicodeScalars.contains { $0.properties.generalCategory == .control }
                    && !c.unicodeScalars.allSatisfy { $0.properties.generalCategory == .format }
            } }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: Moving

    public mutating func moveLeft() { caret = max(0, caret - 1) }
    public mutating func moveRight() { caret = min(text.count, caret + 1) }
    public mutating func moveToStart() { caret = 0 }
    public mutating func moveToEnd() { caret = text.count }
    public mutating func moveWordLeft() { caret = wordStart(before: caret) }
    public mutating func moveWordRight() { caret = wordEnd(after: caret) }

    // MARK: Deleting

    public mutating func deleteBackward() { delete(from: caret - 1, to: caret) }
    public mutating func deleteForward() { delete(from: caret, to: caret + 1) }
    public mutating func deleteWordBackward() { delete(from: wordStart(before: caret), to: caret) }
    public mutating func deleteWordForward() { delete(from: caret, to: wordEnd(after: caret)) }
    public mutating func deleteToStart() { delete(from: 0, to: caret) }
    public mutating func deleteToEnd() { delete(from: caret, to: text.count) }

    private mutating func delete(from start: Int, to end: Int) {
        var start = max(0, start)
        let end = min(text.count, end)
        guard start < end else { return }
        let after = text.dropFirst(end)
        // As with typing, the characters after the deletion stay as they were: where the one
        // before would fuse with them (a lone flag half, which would re-pair every flag after
        // it), it goes too.
        var joined = String(text.prefix(start) + after)
        while start > 0, !joined.suffix(after.count).elementsEqual(after) || joined.count != start + after.count {
            start -= 1
            joined = String(text.prefix(start) + after)
        }
        text = joined
        caret = start
    }

    // MARK: Words

    /// Whether `chars[k]` belongs to a word: a letter or digit, or an apostrophe between
    /// letters, so "don't" is one word, as macOS treats it.
    static func isWord(_ chars: [Character], _ k: Int) -> Bool {
        let c = chars[k]
        if c.isLetter || c.isNumber { return true }
        guard c == "'" || c == "’", k > 0, k + 1 < chars.count else { return false }
        return chars[k - 1].isLetter && chars[k + 1].isLetter
    }

    /// Start of the word before `i`, skipping the separators in between (as ⌥← does).
    private func wordStart(before i: Int) -> Int {
        words().last { $0.lowerBound < i }?.lowerBound ?? 0
    }

    /// End of the word after `i`, skipping the separators in between (as ⌥→ does).
    private func wordEnd(after i: Int) -> Int {
        words().first { $0.upperBound > i }?.upperBound ?? text.count
    }

    /// The words, as character ranges: runs of letters and digits. A run in a script written
    /// without spaces (Chinese, Japanese, Thai) is split where the system's word breaking splits it,
    /// as macOS's own ⌥← and ⌥→ do, rather than crossed in one step.
    private func words() -> [Range<Int>] {
        let chars = Array(text)
        var runs: [Range<Int>] = []
        var j = 0
        while j < chars.count {
            guard Self.isWord(chars, j) else { j += 1; continue }
            let start = j
            while j < chars.count, Self.isWord(chars, j) { j += 1 }
            runs.append(start..<j)
        }
        return runs.flatMap { run -> [Range<Int>] in
            guard chars[run].contains(where: Self.isUnspaced) else { return [run] }
            let piece = String(chars[run])
            var ranges: [Range<Int>] = []
            piece.enumerateSubstrings(in: piece.startIndex..., options: [.byWords, .substringNotRequired]) { _, r, _, _ in
                let lower = piece.distance(from: piece.startIndex, to: r.lowerBound)
                ranges.append(run.lowerBound + lower ..< run.lowerBound + lower + piece[r].count)
            }
            return ranges.isEmpty ? [run] : ranges
        }
    }

    /// Han, hiragana, katakana, Thai, Lao, Khmer and Myanmar: written without spaces between words.
    static func isUnspaced(_ c: Character) -> Bool {
        c.unicodeScalars.contains { s in
            s.properties.isIdeographic || unspacedRanges.contains { $0.contains(s.value) }
        }
    }

    private static let unspacedRanges: [ClosedRange<UInt32>] = [
        0x3040...0x30FF, 0x31F0...0x31FF, // kana
        0x0E00...0x0E7F, 0x0E80...0x0EFF, // Thai, Lao
        0x1000...0x109F, 0x1780...0x17FF, 0x19E0...0x19FF, // Myanmar, Khmer
    ]
}
