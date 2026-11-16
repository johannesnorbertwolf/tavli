import CoreGraphics
import XCTest
@testable import BoardGeometry

/// #109 — the compact/regular layout helper. Sizes are logical points with the
/// devices' real safe-area insets.
final class ChromeLayoutTests: XCTestCase {
    private let eps: CGFloat = 1e-6

    // iPhone 13 mini portrait: 375 × 812, notch 50 / home indicator 34.
    func testMiniPortraitBoardSpansFullSafeWidth() {
        let l = ChromeLayout(container: CGSize(width: 375, height: 812),
                             safeArea: SafeAreaInsets(top: 50, bottom: 34))
        XCTAssertEqual(l.mode, .compactPortrait)
        XCTAssertEqual(l.boardPadding, 0)
        XCTAssertEqual(l.boardRect, CGRect(x: 0, y: 778 - 375, width: 375, height: 375))
        XCTAssertEqual(l.boardRect.maxY, l.safeRect.maxY, accuracy: eps)   // clear of the home indicator
        XCTAssertEqual(l.panelRect, CGRect(x: 0, y: 50, width: 375, height: 403 - 50))
        XCTAssertEqual(l.fontScale, ChromeLayout.compactFontScale)
    }

    // iPhone 13 mini landscape: 812 × 375, 50 pt notch insets both sides, 21 bottom.
    func testMiniLandscapeBoardTakesFullSafeHeight() {
        let l = ChromeLayout(container: CGSize(width: 812, height: 375),
                             safeArea: SafeAreaInsets(top: 0, leading: 50, bottom: 21, trailing: 50))
        XCTAssertEqual(l.mode, .compactLandscape)
        XCTAssertEqual(l.boardRect, CGRect(x: 50, y: 0, width: 354, height: 354))
        // Rail: right of the board, inside the trailing safe edge, full safe height.
        XCTAssertEqual(l.panelRect.minX, 50 + 354 + ChromeLayout.compactRailGap, accuracy: eps)
        XCTAssertEqual(l.panelRect.maxX, 812 - 50 - ChromeLayout.compactRailInset, accuracy: eps)
        XCTAssertEqual(l.panelRect.height, 354, accuracy: eps)
        XCTAssertGreaterThanOrEqual(l.panelRect.width, ChromeLayout.compactMinRailWidth)
    }

    // iPhone 15: 390 × 844 (59 / 34) and 844 × 390 (59 sides / 21 bottom).
    func testIPhone15() {
        let p = ChromeLayout(container: CGSize(width: 390, height: 844),
                             safeArea: SafeAreaInsets(top: 59, bottom: 34))
        XCTAssertEqual(p.mode, .compactPortrait)
        XCTAssertEqual(p.boardSide, 390)
        XCTAssertEqual(p.boardRect.minX, 0)
        XCTAssertEqual(p.boardRect.maxY, 844 - 34)

        let l = ChromeLayout(container: CGSize(width: 844, height: 390),
                             safeArea: SafeAreaInsets(top: 0, leading: 59, bottom: 21, trailing: 59))
        XCTAssertEqual(l.mode, .compactLandscape)
        XCTAssertEqual(l.boardSide, 369)
        XCTAssertEqual(l.boardRect.minX, 59)
    }

    // iPhone 15 Pro Max: 430 × 932 (59 / 34).
    func testIPhone15ProMaxPortrait() {
        let l = ChromeLayout(container: CGSize(width: 430, height: 932),
                             safeArea: SafeAreaInsets(top: 59, bottom: 34))
        XCTAssertEqual(l.mode, .compactPortrait)
        XCTAssertEqual(l.boardRect, CGRect(x: 0, y: 898 - 430, width: 430, height: 430))
    }

    // The board is the largest square the safe area allows (no wasted margin).
    func testCompactBoardIsMaximal() {
        let cases: [(CGSize, SafeAreaInsets)] = [
            (CGSize(width: 375, height: 812), SafeAreaInsets(top: 50, bottom: 34)),
            (CGSize(width: 812, height: 375), SafeAreaInsets(leading: 50, bottom: 21, trailing: 50)),
            (CGSize(width: 390, height: 844), SafeAreaInsets(top: 59, bottom: 34)),
            (CGSize(width: 430, height: 932), SafeAreaInsets(top: 59, bottom: 34)),
        ]
        for (size, insets) in cases {
            let l = ChromeLayout(container: size, safeArea: insets)
            XCTAssertTrue(l.isCompact)
            XCTAssertEqual(l.boardSide, min(l.safeRect.width, l.safeRect.height), "\(size)")
            XCTAssertTrue(l.safeRect.contains(l.boardRect), "\(size)")
            XCTAssertFalse(l.boardRect.intersects(l.panelRect), "\(size)")
        }
    }

    // A nearly square compact window still leaves the rail its minimum width.
    func testLandscapeRailKeepsMinimumWidth() {
        let l = ChromeLayout(container: CGSize(width: 480, height: 400))
        XCTAssertEqual(l.mode, .compactLandscape)
        XCTAssertEqual(l.panelRect.width, ChromeLayout.compactMinRailWidth, accuracy: eps)
        XCTAssertEqual(l.boardSide, 480 - 8 - 8 - 220, accuracy: eps)
    }

    // iPad Pro 12.9": the regular layout reproduces the pre-#109 values exactly.
    func testIPadPortraitMatchesRegularLayout() {
        let l = ChromeLayout(container: CGSize(width: 1024, height: 1366),
                             safeArea: SafeAreaInsets(top: 24, bottom: 20))
        XCTAssertEqual(l.mode, .regular)
        XCTAssertEqual(l.boardPadding, 8)
        XCTAssertEqual(l.fontScale, 1)
        // `.padding(.horizontal, 8)` full-width square, 12 pt above the safe bottom.
        XCTAssertEqual(l.boardRect, CGRect(x: 8, y: 1346 - 12 - 1008, width: 1008, height: 1008))
    }

    func testIPadLandscapeMatchesRegularLayout() {
        let l = ChromeLayout(container: CGSize(width: 1366, height: 1024),
                             safeArea: SafeAreaInsets(top: 24, bottom: 20))
        XCTAssertEqual(l.mode, .regular)
        // Board column = width − 280 panel − 12 inset; square limited by height − 2·8.
        XCTAssertEqual(l.boardRect, CGRect(x: 8, y: 24 + 8, width: 964, height: 964))
        XCTAssertEqual(l.panelRect, CGRect(x: 1366 - 12 - 280, y: 24 + 12, width: 280, height: 980 - 24))
    }

    func testIPadMiniIsRegular() {
        XCTAssertFalse(ChromeLayout.isCompact(container: CGSize(width: 744, height: 1133)))
        XCTAssertFalse(ChromeLayout.isCompact(container: CGSize(width: 1133, height: 744)))
        XCTAssertEqual(ChromeLayout.fontScale(forScreen: CGSize(width: 744, height: 1133)), 1)
    }

    func testFontScaleIsPerScreenNotPerOrientation() {
        XCTAssertEqual(ChromeLayout.fontScale(forScreen: CGSize(width: 375, height: 812)),
                       ChromeLayout.fontScale(forScreen: CGSize(width: 812, height: 375)))
        XCTAssertLessThan(ChromeLayout.fontScale(forScreen: CGSize(width: 430, height: 932)), 1)
    }
}
