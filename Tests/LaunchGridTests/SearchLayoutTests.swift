import Foundation
import Testing
@testable import LaunchGrid
@testable import LaunchGridCore

/// Search results: the top hit alone on the first row, the rest in centred rows.
@MainActor struct SearchLayoutTests {
    let grid = Grid(rows: 4, columns: 5)
    var page: GridLayout { GridLayout(size: CGSize(width: 1000, height: 800), rows: 4, columns: 5) }

    @Test func theFirstPageHoldsTheTopHitAndFullRowsBelowIt() {
        #expect(SearchLayout.firstPageCapacity(grid) == 16)
        #expect(SearchLayout.pageCount(results: 0, grid: grid) == 1)
        #expect(SearchLayout.pageCount(results: 16, grid: grid) == 1)
        #expect(SearchLayout.pageCount(results: 17, grid: grid) == 2)
        #expect(SearchLayout.pageCount(results: 36, grid: grid) == 2)
        #expect(SearchLayout.pageCount(results: 37, grid: grid) == 3)
        #expect(SearchLayout.pageStart(0, grid: grid) == 0)
        #expect(SearchLayout.pageStart(1, grid: grid) == 16)
        #expect(SearchLayout.pageStart(2, grid: grid) == 36)
        for i in [0, 15, 16, 35, 36, 50] {
            let p = SearchLayout.page(of: i, grid: grid)
            #expect(i >= SearchLayout.pageStart(p, grid: grid))
            #expect(i < SearchLayout.pageStart(p, grid: grid) + SearchLayout.capacity(page: p, grid: grid))
        }
    }

    @Test func rowsStandCentredWithTheTopHitInTheMiddle() {
        let places = SearchLayout(grid: page, count: 5, hero: true)
        #expect(places.center(0).x == 500)
        // Four results below it, either side of the middle.
        #expect(abs(places.center(1).x + places.center(4).x - 1000) < 0.001)
        #expect(places.center(1).y == places.center(2).y)
        #expect(places.center(1).y > places.center(0).y)
        // The top hit's row is the taller.
        #expect(places.heroRowHeight > places.rowHeight)
        #expect(abs(places.heroRowHeight + 3 * places.rowHeight - 800) < 0.001)
    }

    @Test func aFewResultsAllStandOnTheTopHitsRow() {
        for n in 1...3 {
            let places = SearchLayout(grid: page, count: n, hero: true)
            #expect(places.topRowCount == n)
            #expect((0..<n).allSatisfy { places.slot($0).row == 0 && places.inTopRow($0) })
            // Centred together, spaced wider than the cells below for their larger icons.
            let xs = (0..<n).map { places.center($0).x }
            #expect(abs(xs.first! + xs.last! - 1000) < 0.001)
            if n > 1 { #expect(xs[1] - xs[0] >= page.cell.width) }
            for i in 0..<n { #expect(places.index(at: places.center(i)) == i) }
            #expect(places.vertical(from: 0, by: 1) == nil)
            // Never wider than the space between them.
            if n > 1 { #expect(places.topRowWidth(heroIconSize: 150) <= xs[1] - xs[0] + 0.001) }
        }
        // One more, and the top hit stands alone again with the rest below.
        let four = SearchLayout(grid: page, count: 4, hero: true)
        #expect(four.topRowCount == 1)
        #expect(four.slot(1).row == 1)
        // Later pages are plain rows.
        #expect(SearchLayout(grid: page, count: 2, hero: false).topRowCount == 0)
    }

    @Test func hitTestingAgreesWithWhereResultsAreDrawn() {
        let places = SearchLayout(grid: page, count: 8, hero: true)
        for i in 0..<8 { #expect(places.index(at: places.center(i)) == i) }
        // Beside the top hit, and past the short last row: nothing.
        #expect(places.index(at: CGPoint(x: 20, y: places.center(0).y)) == nil)
        #expect(places.index(at: CGPoint(x: 990, y: places.center(7).y)) == nil)
        #expect(places.index(at: CGPoint(x: 500, y: 790)) == nil)
    }

    @Test func upAndDownGoToTheNearestResultAcross() {
        let places = SearchLayout(grid: page, count: 13, hero: true)
        // From the top hit, down lands on the middle of the full row below.
        #expect(places.vertical(from: 0, by: 1) == 3)
        #expect(places.vertical(from: 5, by: -1) == 0)
        #expect(places.vertical(from: 0, by: -1) == nil)
        // Onto the short last row (11, 12 centred): the nearest across.
        #expect(places.vertical(from: 6, by: 1) == 11)
        #expect(places.vertical(from: 10, by: 1) == 12)
        #expect(places.vertical(from: 12, by: 1) == nil)
    }

    @Test func theTopHitFitsItsRowInATightGrid() {
        // Large icons on many short rows: the top hit's row is no taller than an ordinary cell
        // until the rows below give up some of their margin for its caption.
        for (rows, height, scale) in [(6, 1000.0, 1.4), (5, 700.0, 1.3), (5, 800.0, 1.0), (4, 800.0, 1.0), (7, 600.0, 1.4)] {
            let tight = GridLayout(size: CGSize(width: 1400, height: height), rows: rows, columns: 5)
            let icon = tight.iconSize(scale: scale, labels: true)
            let places = SearchLayout(grid: tight, count: 4, hero: true,
                                      minRowHeight: SearchLayout.minRowHeight(iconSize: icon, labels: true),
                                      captionRoom: SearchLayout.captionHeight(iconSize: icon))
            let hero = places.heroIconSize(iconSize: icon, labels: true)
            #expect(hero >= icon)
            let before = SearchLayout(grid: tight, count: 4, hero: true,
                                      minRowHeight: SearchLayout.minRowHeight(iconSize: icon, labels: true))
            // Its icon, name and (when it shows) caption fit its row as an ordinary tile's icon
            // and name fit theirs: the caption never runs into the row below.
            let caption = places.heroFitsCaption ? SearchLayout.captionHeight(iconSize: hero) : 0
            #expect(hero + GridLayout.labelHeight(iconSize: hero) + caption <= places.heroRowHeight + 0.5, "\(rows) rows, \(height)")
            if places.heroFitsCaption {
                #expect(hero + 16 + GridLayout.labelHeight(iconSize: hero) + caption <= places.heroRowHeight + 0.5)
            }
            print("tight \(rows)x\(height)@\(scale): icon \(Int(icon)) hero row \(Int(places.heroRowHeight)) rows \(Int(before.rowHeight))→\(Int(places.rowHeight)) caption \(places.heroFitsCaption)")
            // The rows below give up no more than their margin, and the rows still fill the page.
            #expect(places.rowHeight >= min(before.rowHeight, places.minRowHeight - SearchLayout.rowSlack) - 0.001)
            // The rows in use still fit the page.
            let lastRow = places.slot(3).row
            #expect(places.heroRowHeight + CGFloat(lastRow) * places.rowHeight <= height + 0.001)
        }
        // A tight grid with a few results: the top hit's row takes its height from the empty
        // rows below, a third more than a cell and room for its caption, so it doesn't crowd
        // the row under it, and keeps that height as results are added until the page is full.
        let tight = GridLayout(size: CGSize(width: 1400, height: 1000), rows: 6, columns: 5)
        let icon = tight.iconSize(scale: 1.4, labels: true)
        func places(_ n: Int) -> SearchLayout {
            SearchLayout(grid: tight, count: n, hero: true,
                         minRowHeight: SearchLayout.minRowHeight(iconSize: icon, labels: true),
                         captionRoom: SearchLayout.captionHeight(iconSize: icon))
        }
        let seven = places(7)
        #expect(seven.heroRowHeight >= tight.cell.height * 1.3 - 0.001)
        #expect(seven.heroFitsCaption)
        #expect(seven.rowHeight >= tight.cell.height - 0.001, "the rows in use keep their height")
        #expect(places(12).heroRowHeight == seven.heroRowHeight)
        // Full: everything fits the page again.
        let full = places(SearchLayout.firstPageCapacity(Grid(rows: 6, columns: 5)))
        #expect(full.heroRowHeight + 5 * full.rowHeight <= 1000.001)
        // With room to spare, it's larger than the rest, with its caption.
        let roomy = SearchLayout(grid: page, count: 4, hero: true, minRowHeight: 120, captionRoom: 18)
        #expect(roomy.heroIconSize(iconSize: 100, labels: true) > 100)
        #expect(roomy.heroFitsCaption)
    }

    @Test func laterPagesArePlainCentredRows() {
        let places = SearchLayout(grid: page, count: 7, hero: false)
        #expect(places.slot(0) == (0, 0))
        #expect(places.slot(6) == (1, 1))
        #expect(places.heroRowHeight == places.rowHeight)
        #expect(places.vertical(from: 2, by: 1) == 5 || places.vertical(from: 2, by: 1) == 6)
    }
}
