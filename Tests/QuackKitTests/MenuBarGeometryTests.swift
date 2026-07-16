import Testing
import CoreGraphics
@testable import QuackKit

@Suite struct MenuBarGeometryTests {
    // Built-in primary: Cocoa frame (0,0,1512,982) → primaryHeight 982.
    // External above it: Cocoa frame (0,982,2560,1440), maxY 2422.
    private let thickness: CGFloat = 24

    @Test func primaryMenuBarBandSitsAtQuartzZero() {
        let band = MenuBarGeometry.topLeftBand(screenMaxYCocoa: 982, primaryHeight: 982, thickness: thickness)
        // Built-in menu-bar items report midY ≈ 12 (top-left origin).
        #expect(band.contains(12))
        #expect(band.lowerBound == -5)
        #expect(band.upperBound == 36)
    }

    @Test func externalMenuBarBandSitsAbovePrimary() {
        // External top edge in Quartz top-left = 982 - 2422 = -1440.
        let band = MenuBarGeometry.topLeftBand(screenMaxYCocoa: 2422, primaryHeight: 982, thickness: thickness)
        #expect(band.contains(-1425))     // an external menu-bar item's midY
        #expect(!band.contains(12))        // must NOT swallow primary-bar items
    }

    @Test func bandsCoverEveryScreenTop() {
        let screens: [CGFloat] = [982, 2422]   // Cocoa maxY of each screen
        let bands = screens.map { MenuBarGeometry.topLeftBand(screenMaxYCocoa: $0, primaryHeight: 982, thickness: thickness) }
        #expect(bands.contains { $0.contains(12) })      // primary item matched
        #expect(bands.contains { $0.contains(-1425) })   // external item matched
    }
}
