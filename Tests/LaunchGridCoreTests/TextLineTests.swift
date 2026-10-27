import Testing
@testable import LaunchGridCore

@Suite struct TextLineTests {
    func line(_ marked: String) -> TextLine {
        let caret = marked.distance(from: marked.startIndex, to: marked.firstIndex(of: "|")!)
        return TextLine(text: marked.replacingOccurrences(of: "|", with: ""), caret: caret)
    }

    func marked(_ l: TextLine) -> String { l.beforeCaret + "|" + l.afterCaret }

    func after(_ start: String, _ edit: (inout TextLine) -> Void) -> String {
        var l = line(start)
        edit(&l)
        return marked(l)
    }

    @Test func caretStartsAtTheEnd() {
        #expect(marked(TextLine(text: "abc")) == "abc|")
        #expect(marked(TextLine(text: "abc", caret: 9)) == "abc|")
    }

    @Test func insertsAtTheCaret() {
        #expect(after("ab|cd") { $0.insert("XY") } == "abXY|cd")
    }

    @Test func insertingACharacterThatMergesKeepsTheCaretAfterIt() {
        var l = line("e|x")
        l.insert("\u{301}")
        #expect(l.text == "\u{E9}x")
        #expect(l.caret == 1)
        l.deleteBackward()
        #expect(marked(l) == "|x")
        var flag = line("|")
        flag.insert("\u{1F1FA}")
        flag.insert("\u{1F1F8}")
        #expect(flag.caret == 1)
        flag.deleteBackward()
        #expect(flag.text.isEmpty)
    }

    @Test func insertingNeverChangesTheCharactersAfterTheCaret() {
        let fr = "\u{1F1EB}\u{1F1F7}", de = "\u{1F1E9}\u{1F1EA}", us = "\u{1F1FA}\u{1F1F8}"
        var l = line("|" + fr + de)
        l.insert("\u{1F1FA}")
        #expect(l.text == fr + de, "a lone half would re-pair both flags")
        #expect(l.caret == 0)
        l.insert(us)
        #expect(marked(l) == us + "|" + fr + de, "a whole flag goes in")
        #expect(after("|" + fr) { $0.insert("a") } == "a|" + fr)
    }

    @Test func deletingNeverChangesTheCharactersAfterIt() {
        let fr = "\u{1F1EB}\u{1F1F7}", de = "\u{1F1E9}\u{1F1EA}"
        // A lone flag half before the deleted "x" would pair off with the first flag's half.
        #expect(after("\u{1F1FA}x|" + fr + de) { $0.deleteBackward() } == "|" + fr + de)
        #expect(after("\u{1F1FA}|x" + fr + de) { $0.deleteForward() } == "|" + fr + de)
        // Korean jamo either side of the deleted character would fuse into one syllable.
        #expect(after("a\u{1100}x|\u{1161}") { $0.deleteBackward() } == "a|\u{1161}")
        #expect(after("ab|c") { $0.deleteBackward() } == "a|c")
    }

    @Test func movesByCharacterAndToEitherEnd() {
        #expect(after("ab|c") { $0.moveLeft() } == "a|bc")
        #expect(after("|abc") { $0.moveLeft() } == "|abc")
        #expect(after("ab|c") { $0.moveRight() } == "abc|")
        #expect(after("abc|") { $0.moveRight() } == "abc|")
        #expect(after("ab|c") { $0.moveToStart() } == "|abc")
        #expect(after("a|bc") { $0.moveToEnd() } == "abc|")
    }

    @Test func movesByWordSkippingSeparators() {
        #expect(after("final cut pro|") { $0.moveWordLeft() } == "final cut |pro")
        #expect(after("final cut |pro") { $0.moveWordLeft() } == "final |cut pro")
        #expect(after("final cu|t pro") { $0.moveWordLeft() } == "final |cut pro")
        #expect(after("|final cut") { $0.moveWordRight() } == "final| cut")
        #expect(after("final| cut") { $0.moveWordRight() } == "final cut|")
        #expect(after("a - |") { $0.moveWordLeft() } == "|a - ")
        #expect(after("don't|") { $0.moveWordLeft() } == "|don't", "an apostrophe inside a word")
        #expect(after("|rock’n roll") { $0.moveWordRight() } == "rock’n| roll")
        #expect(after("'quoted'|") { $0.moveWordLeft() } == "'|quoted'")
    }

    @Test func movesByWordInsideTextWrittenWithoutSpaces() {
        var line = TextLine(text: "网易云音乐")
        line.moveWordLeft()
        #expect(line.caret > 0, "not across the whole run in one step")
        var steps = 1
        while line.caret > 0 && steps < 10 { line.moveWordLeft(); steps += 1 }
        #expect(line.caret == 0 && steps > 1)
        var mixed = TextLine(text: "Final Cut 视频编辑")
        mixed.moveToStart()
        mixed.moveWordRight()
        #expect(mixed.caret == 5, "Latin words as before")
        var thai = TextLine(text: "ภาษาไทยง่ายมาก")
        thai.moveWordLeft()
        #expect(thai.caret > 0, "Thai is written without spaces too")
    }

    @Test func deletesAroundTheCaret() {
        #expect(after("ab|c") { $0.deleteBackward() } == "a|c")
        #expect(after("|abc") { $0.deleteBackward() } == "|abc")
        #expect(after("ab|c") { $0.deleteForward() } == "ab|")
        #expect(after("abc|") { $0.deleteForward() } == "abc|")
        #expect(after("final cut| pro") { $0.deleteWordBackward() } == "final | pro")
        #expect(after("final |cut pro") { $0.deleteWordForward() } == "final | pro")
        #expect(after("final cut| pro") { $0.deleteToStart() } == "| pro")
        #expect(after("final cut| pro") { $0.deleteToEnd() } == "final cut|")
    }

    @Test func countsGraphemesNotScalars() {
        #expect(after("café|") { $0.deleteBackward() } == "caf|")
        #expect(after("a👍🏽|b") { $0.moveLeft() } == "a|👍🏽b")
    }

    @Test func pastedTextBecomesOneLine() {
        #expect(TextLine.singleLine("Final\r\nCut\tPro\n") == "Final Cut Pro")
        #expect(TextLine.singleLine("  Safari  ") == "Safari")
        #expect(TextLine.singleLine("a\u{7}b \u{1B}") == "ab")
        #expect(TextLine.singleLine("\n\r\n\t") == "")
        #expect(TextLine.singleLine("café 👍🏽") == "café 👍🏽")
        #expect(TextLine.singleLine("\u{202E}Safari\u{200B}") == "Safari", "invisible format characters")
        #expect(TextLine.singleLine("👨‍👩‍👧 🏴󠁧󠁢󠁳󠁣󠁴󠁿") == "👨‍👩‍👧 🏴󠁧󠁢󠁳󠁣󠁴󠁿", "joiners and tags inside emoji stay")
    }
}
