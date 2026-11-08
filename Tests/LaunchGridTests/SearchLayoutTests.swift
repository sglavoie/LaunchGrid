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
        let places = SearchLayout(grid: page, count: 3, hero: true)
        #expect(places.center(0).x == 500)
        // Two results below it, either side of the middle.
        #expect(abs(places.center(1).x + places.center(2).x - 1000) < 0.001)
        #expect(places.center(1).y == places.center(2).y)
        #expect(places.center(1).y > places.center(0).y)
        // The top hit's row is the taller.
        #expect(places.heroRowHeight > places.rowHeight)
        #expect(abs(places.heroRowHeight + 3 * places.rowHeight - 800) < 0.001)
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

    @Test func laterPagesArePlainCentredRows() {
        let places = SearchLayout(grid: page, count: 7, hero: false)
        #expect(places.slot(0) == (0, 0))
        #expect(places.slot(6) == (1, 1))
        #expect(places.heroRowHeight == places.rowHeight)
        #expect(places.vertical(from: 2, by: 1) == 5 || places.vertical(from: 2, by: 1) == 6)
    }
}
