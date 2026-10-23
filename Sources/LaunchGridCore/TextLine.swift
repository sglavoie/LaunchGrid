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
        text = head + afterCaret
        caret = min(head.count, text.count)
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
        let start = max(0, start), end = min(text.count, end)
        guard start < end else { return }
        text = String(text.prefix(start) + text.dropFirst(end))
        caret = start
    }

    // MARK: Words

    private static func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    /// Start of the word before `i`, skipping the separators in between (as ⌥← does).
    private func wordStart(before i: Int) -> Int {
        let chars = Array(text)
        var j = i
        while j > 0, !Self.isWord(chars[j - 1]) { j -= 1 }
        while j > 0, Self.isWord(chars[j - 1]) { j -= 1 }
        return j
    }

    /// End of the word after `i`, skipping the separators in between (as ⌥→ does).
    private func wordEnd(after i: Int) -> Int {
        let chars = Array(text)
        var j = i
        while j < chars.count, !Self.isWord(chars[j]) { j += 1 }
        while j < chars.count, Self.isWord(chars[j]) { j += 1 }
        return j
    }
}
