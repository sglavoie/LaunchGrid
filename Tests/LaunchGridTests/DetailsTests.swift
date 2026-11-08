import AppKit
import Foundation
import Testing
import os
@testable import LaunchGrid
@testable import LaunchGridCore

/// The small touches: the new-app dot, tips, answers, the keyword token, files dragged over
/// the grid, the hot corner, the background's drift, icon tints and the show timings.
@MainActor @Suite(.tempDir) struct DetailsTests {
    @Test func anAppAutoAddedIsNewUntilOpenedElsewhereOrGone() {
        let state = makeState(["A"])
        state.prefs.autoAddApps = true
        state.catalogScanned([installed("A")])
        #expect(state.prefs.newAppPaths.isEmpty)
        // B installed while LaunchGrid runs: added at the end, with the dot.
        state.catalogScanned([installed("A"), installed("B")])
        let b = state.grid.allApps.first { $0.name == "B" }
        #expect(b.map(state.isNew) == true)
        #expect(!state.isNew(state.grid.allApps[0]))
        // Gone from the grid (uninstalled), it loses its mark.
        state.catalogScanned([installed("A")])
        #expect(state.prefs.newAppPaths.isEmpty)
    }

    @Test func tipsGoOneAtATimeAsTheyreTaken() {
        let state = makeState(["A"])
        #expect(state.currentTip == .typeToSearch)
        state.query = "a"
        #expect(state.currentTip == .holdCommand)
        state.noteTip(.holdCommand)
        #expect(state.currentTip == .allShortcuts)
        // Opening the Keyboard Shortcuts panel is what it says.
        state.showingShortcuts = true
        #expect(state.currentTip == .dropFile)
        state.noteTip(.dropFile)
        #expect(state.currentTip == nil)
        // Kept in the settings.
        let again = Preferences(defaults: UserDefaults(suiteName: TempDir.suiteName(for: TempDir.url))!)
        #expect(again.tipsSeen == ["typeToSearch", "holdCommand", "allShortcuts", "dropFile"])
    }

    @Test func anAnswerComesBeforeTheResults() {
        let state = makeState(["Calculator"])
        state.query = "12*7"
        #expect(state.searchAnswer?.value == "84")
        // Nothing focused: Return copies the answer rather than opening a result.
        #expect(state.focusIndex == nil)
        state.query = "calc"
        #expect(state.searchAnswer == nil)
        #expect(state.focusIndex == 0)
    }

    @Test func aKeywordTypedWithSomethingAfterItShowsAsAToken() throws {
        let state = makeState(["A"])
        let gh = Action(name: "Search GitHub", keywords: ["gh"], kind: .openURL(template: "https://github.com/search?q={query}"))
        state.apply { $0.pages[0].items.append(.action(gh)) }
        state.query = "gh launch grid"
        let split = try #require(KeywordChip.split(state, line: state.searchLine))
        #expect(split.keyword == "gh" && split.beforeCaret == "launch grid" && split.action.id == gh.id)
        // The caret back inside the keyword: plain text again.
        var line = state.searchLine
        line.moveToStart()
        state.searchLine = line
        #expect(KeywordChip.split(state, line: state.searchLine) == nil)
        // A name match isn't a keyword.
        state.query = "search"
        #expect(KeywordChip.split(state, line: state.searchLine) == nil)
    }

    @Test func draggedFilesLightUpTheAppsThatOpenThemAndSpringFoldersOpen() throws {
        let state = makeState()
        let textEdit = AppRef(bundleID: "com.apple.TextEdit", path: "/System/Applications/TextEdit.app", name: "TextEdit")
        let fake = AppRef(bundleID: "com.test.none", path: "/Applications/Nothing.app", name: "Nothing")
        let folder = Folder(name: "F", apps: [AppRef(bundleID: "com.test.x", path: "/Applications/X.app", name: "X")])
        state.replaceGrid(Grid(rows: 5, columns: 7, pages: [Page(items: [.app(textEdit), .app(fake), .folder(folder)])]))
        state.drag.pagerFrame = CGRect(x: 0, y: 0, width: 700, height: 500)
        let cell = state.pageLayout.cell
        let center = { (i: Int) in CGPoint(x: (CGFloat(i) + 0.5) * cell.width, y: cell.height / 2) }
        try FileManager.default.createDirectory(at: TempDir.url, withIntermediateDirectories: true)
        let file = TempDir.url.appendingPathComponent("note.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        state.beginFileDrag([file])
        #expect(state.canOpenDraggedFiles(with: textEdit))
        #expect(!state.canOpenDraggedFiles(with: fake))
        #expect(state.fileDragMoved(to: center(0)))
        #expect(state.fileDrag?.target == textEdit.id)
        #expect(!state.fileDragMoved(to: center(1)))
        #expect(state.fileDropItem(at: center(2))?.id == folder.id)
        // Resting on the folder opens it.
        state.fileDwell = FileDwell(spot: .folder(folder.id), since: Date().addingTimeInterval(-1))
        state.fileDragMoved(to: center(2))
        #expect(state.openFolderID == folder.id)
        state.endFileDrag()
        #expect(state.fileDrag == nil)
    }

    @Test func theHotCornerIsTheCornerAsked() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 600)
        #expect(GestureWatcher.isInCorner(.topLeft, point: CGPoint(x: 1, y: 599), of: screen))
        #expect(GestureWatcher.isInCorner(.bottomRight, point: CGPoint(x: 999, y: 0), of: screen))
        #expect(!GestureWatcher.isInCorner(.bottomRight, point: CGPoint(x: 999, y: 300), of: screen))
        #expect(!GestureWatcher.isInCorner(.topRight, point: CGPoint(x: 1, y: 599), of: screen))
        #expect(!GestureWatcher.isInCorner(.none, point: .zero, of: screen))
        // A second display to the left.
        let left = CGRect(x: -800, y: 0, width: 800, height: 600)
        #expect(GestureWatcher.isInCorner(.bottomLeft, point: CGPoint(x: -800, y: 2), of: left))
    }

    @Test func theBackgroundDriftsAcrossThePages() {
        #expect(Parallax.offset(page: 0, swipe: 0, pageWidth: 1000, pages: 1) == 0)
        // Three pages: the middle one centred, either end 18 points off, the other way.
        #expect(Parallax.offset(page: 0, swipe: 0, pageWidth: 1000, pages: 3) == 18)
        #expect(Parallax.offset(page: 1, swipe: 0, pageWidth: 1000, pages: 3) == 0)
        #expect(Parallax.offset(page: 2, swipe: 0, pageWidth: 1000, pages: 3) == -18)
        // Half-way through a swipe to the next page, half-way there.
        #expect(Parallax.offset(page: 0, swipe: -500, pageWidth: 1000, pages: 3) == 9)
        // Past the end (the rubber band), only a little further.
        #expect(Parallax.offset(page: 2, swipe: -900, pageWidth: 1000, pages: 3) == -22.5)
        // Many pages: the whole run stays within 90 points.
        #expect(Parallax.reach(pages: 20) <= 45)
    }

    @Test func anIconsTintIsItsMostVividColour() throws {
        func bitmap(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) throws -> NSBitmapImageRep {
            let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4,
                                                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            for x in 0..<16 { for y in 0..<16 { rep.setColor(NSColor(deviceRed: r, green: g, blue: b, alpha: 1), atX: x, y: y) } }
            return rep
        }
        let red = try #require(IconProvider.tint(of: try bitmap(0.8, 0.1, 0.1)))
        #expect(red.red > 0.8 && red.green < 0.4 && red.blue < 0.4)
        // Grey has no colour to glow with.
        #expect(IconProvider.tint(of: try bitmap(0.5, 0.5, 0.5)) == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func anIconFirstDrawnAsAPlaceholderIsDrawnAgain() async throws {
        // The first draw is blank, as macOS hands out while it renders a new icon style; the next is real.
        let draws = OSAllocatedUnfairLock(initialState: 0)
        let provider = IconProvider(source: { _ in
            let n = draws.withLock { $0 += 1; return $0 }
            return SendableImage(image: n == 1 ? NSImage(size: NSSize(width: 64, height: 64)) : NSWorkspace.shared.icon(forFile: "/System/Applications/Calculator.app"))
        })
        let redrawn = OSAllocatedUnfairLock(initialState: false)
        provider.onRedrawn = { redrawn.withLock { $0 = true } }
        let first = await provider.icon("/System/Applications/Calculator.app")
        let firstRep = try #require(first.representations.first as? NSBitmapImageRep)
        #expect(!IconProvider.looksDrawn(firstRep))
        while !redrawn.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(50)) }
        let again = try #require(provider.cached("/System/Applications/Calculator.app")?.representations.first as? NSBitmapImageRep)
        #expect(IconProvider.looksDrawn(again))
        #expect(draws.withLock { $0 } == 2)
    }

    @Test func showTimesSummariseColdAndWarm() {
        let saved = ShowTiming.samples
        defer { ShowTiming.samples = saved }
        ShowTiming.samples = []
        #expect(ShowTiming.summary == "no shows yet")
        ShowTiming.samples = [120, 20, 30, 10]
        #expect(ShowTiming.summary == "cold 120 ms, warm p50 20 ms, p95 30 ms (n=3)")
    }
}
