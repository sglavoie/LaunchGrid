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
}
