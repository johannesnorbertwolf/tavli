import Foundation
import XCTest
@testable import TavliEngine

/// `MoveNotation` (#178): mover-relative numbering, off/bar, chaining + grouping,
/// hit/pin marks, mother pinned, no move, ordering — for all four rule sets and both
/// colours. Pure; no fixtures or model.
final class MoveNotationTests: XCTestCase {
    // ── Helpers ──────────────────────────────────────────────────────────────

    private func config(_ v: any GameVariant) -> GameConfig { GameConfig(variant: v) }

    private func startBoard(_ v: any GameVariant) -> GameBoard {
        let b = GameBoard(config: config(v))
        v.setUpInitialPosition(on: b)
        return b
    }

    /// A board with the given stacks (index → bottom-to-top pieces), everything else empty.
    private func board(_ v: any GameVariant, _ stacks: [Int: [Color]]) -> GameBoard {
        let b = GameBoard(config: config(v))
        b.clear()
        for (i, pieces) in stacks { b.setPoint(i, pieces: pieces) }
        return b
    }

    private func w(_ n: Int) -> [Color] { Array(repeating: .white, count: n) }
    private func k(_ n: Int) -> [Color] { Array(repeating: .black, count: n) }

    private func text(_ pairs: [[Int]], _ d1: Int, _ d2: Int, _ mover: Color, _ b: GameBoard) -> String {
        MoveNotation.describe(pairs, die1: d1, die2: d2, mover: mover, before: b).text
    }

    // ── House Plakoto ────────────────────────────────────────────────────────

    func testPlakotoWhiteNumbersFromItsOwnSide() {
        let b = startBoard(GameVariants.plakoto)
        XCTAssertEqual(text([[1, 7], [1, 5]], 6, 4, .white, b), "64: 24/18 24/20")
        // Dice are shown high first whatever the roll order.
        XCTAssertEqual(text([[1, 5], [1, 7]], 4, 6, .white, b), "64: 24/18 24/20")
    }

    func testPlakotoBlackNumbersFromItsOwnSide() {
        let b = startBoard(GameVariants.plakoto)
        XCTAssertEqual(text([[24, 18], [24, 20]], 6, 4, .black, b), "64: 24/18 24/20")
    }

    func testPlakotoMergedHalfIsOneSegment() {
        let b = startBoard(GameVariants.plakoto)
        XCTAssertEqual(text([[1, 11]], 6, 4, .white, b), "64: 24/14")
        XCTAssertEqual(text([[24, 14]], 6, 4, .black, b), "64: 24/14")
    }

    func testPlakotoDoublesGroupAndChain() {
        let b = startBoard(GameVariants.plakoto)
        XCTAssertEqual(text([[1, 4], [1, 4], [1, 4], [1, 4]], 3, 3, .white, b), "33: 24/21(4)")
        XCTAssertEqual(text([[1, 4], [4, 7], [1, 4], [4, 7]], 3, 3, .white, b), "33: 24/18(2)")
        XCTAssertEqual(text([[1, 4], [1, 4], [4, 7]], 3, 3, .white, b), "33: 24/18 24/21")
        XCTAssertEqual(text([[24, 21], [21, 18], [18, 15], [15, 12]], 3, 3, .black, b), "33: 24/12")
    }

    func testPlakotoPinMarksTheLandingPoint() {
        // A black blot on 7 (White's 18 point).
        let b = board(GameVariants.plakoto, [1: w(14), 7: k(1), 24: k(14)])
        let n = MoveNotation.describe([[1, 7], [1, 3]], die1: 6, die2: 2, mover: .white, before: b)
        XCTAssertEqual(n.text, "62: 24/18^ 24/22")
        XCTAssertEqual(n.segments.first?.mark, .pin)
        XCTAssertNil(n.segments.last?.mark)
        XCTAssertFalse(n.motherPinned)                 // house rules: no mother label
        // The board passed in is left untouched.
        XCTAssertEqual(b.points[7].pieces, k(1))
        XCTAssertEqual(b.points[1].count, 14)
    }

    func testPlakotoBlackPin() {
        // A white blot on 16: Black's 16 point.
        let b = board(GameVariants.plakoto, [1: w(14), 16: w(1), 24: k(15)])
        XCTAssertEqual(text([[24, 16]], 6, 2, .black, b), "62: 24/16^")
    }

    func testPinOnlyOnTheFirstLanderAndNotForAnExistingPin() {
        let b = board(GameVariants.plakoto, [1: w(13), 3: w(1), 7: k(1), 24: k(14)])
        // Two checkers land on 7: only the first (highest) segment is marked.
        XCTAssertEqual(text([[1, 7], [3, 7]], 6, 4, .white, b), "64: 24/18^ 22/18")
        // Already pinned there: another checker landing is not a new pin.
        let pinned = board(GameVariants.plakoto, [1: w(14), 7: [.black, .white], 24: k(14)])
        XCTAssertEqual(text([[1, 7]], 6, 1, .white, pinned), "61: 24/18")
    }

    func testPlakotoTransientPinIsNotMarked() {
        // Landing on a blot mid-double and moving on releases it: no ^.
        let b = board(GameVariants.plakoto, [1: w(14), 4: k(1), 24: k(14)])
        XCTAssertEqual(text([[1, 4], [4, 7]], 3, 3, .white, b), "33: 24/18")
    }

    func testPlakotoBearOffBothColours() {
        let wb = board(GameVariants.plakoto, [22: w(2), 24: w(13), 0: k(15)])
        XCTAssertEqual(text([[22, 25], [24, 25]], 3, 1, .white, wb), "31: 3/off 1/off")
        let bb = board(GameVariants.plakoto, [3: k(2), 1: k(13), 25: w(15)])
        XCTAssertEqual(text([[3, 0], [1, 0]], 3, 1, .black, bb), "31: 3/off 1/off")
        XCTAssertEqual(text([[22, 25], [22, 25]], 3, 3, .white, wb), "33: 3/off(2)")
    }

    func testNoMove() {
        let n = MoveNotation.describe([], die1: 6, die2: 6, mover: .white,
                                      before: startBoard(GameVariants.plakoto))
        XCTAssertTrue(n.noMove)
        XCTAssertEqual(n.moveText, "No move")
        XCTAssertEqual(n.text, "66: No move")
        XCTAssertFalse(n.motherPinned)
    }

    func testHighestPointFirst() {
        let b = board(GameVariants.plakoto, [1: w(14), 7: w(1), 24: k(15)])
        XCTAssertEqual(text([[7, 9], [1, 5]], 4, 2, .white, b), "42: 24/20 18/16")
    }

    func testStructuredParts() {
        let b = board(GameVariants.plakoto, [1: w(14), 7: k(1), 24: k(14)])
        let n = MoveNotation.describe([[1, 7]], die1: 2, die2: 6, mover: .white, before: b)
        XCTAssertEqual(n.highDie, 6)
        XCTAssertEqual(n.lowDie, 2)
        XCTAssertEqual(n.diceText, "62")
        XCTAssertEqual(n.segments, [MoveNotation.Segment(from: .point(24),
                                                          stops: [.init(place: .point(18), mark: .pin)])])
        XCTAssertEqual(n.segments[0].to, .point(18))
    }

    // ── Standard Plakoto ─────────────────────────────────────────────────────

    func testStandardPlakotoMotherPinned() {
        let v = GameVariants.plakotoStandard
        // Black's mother alone on its start (24); White hits it from its 7 point (18).
        let b = board(v, [1: w(14), 18: w(1), 24: k(1), 12: k(14)])
        let n = MoveNotation.describe([[18, 24]], die1: 6, die2: 3, mover: .white, before: b)
        XCTAssertEqual(n.segments.map(\.text), ["7/1^"])
        XCTAssertTrue(n.motherPinned)
        XCTAssertEqual(n.text, "63: 7/1^ (mother pinned)")
        // Black pinning White's mother (on 1).
        let bb = board(v, [1: w(1), 13: w(14), 7: k(1), 24: k(14)])
        let m = MoveNotation.describe([[7, 1]], die1: 6, die2: 5, mover: .black, before: bb)
        XCTAssertEqual(m.moveText, "7/1^")
        XCTAssertTrue(m.motherPinned)
        // An ordinary pin is not a mother.
        let o = board(v, [1: w(14), 7: k(1), 24: k(14)])
        let p = MoveNotation.describe([[1, 7]], die1: 6, die2: 1, mover: .white, before: o)
        XCTAssertEqual(p.moveText, "24/18^")
        XCTAssertFalse(p.motherPinned)
    }

    func testHousePlakotoHasNoMotherLabel() {
        let b = board(GameVariants.plakoto, [1: w(14), 18: w(1), 24: k(1), 12: k(14)])
        let n = MoveNotation.describe([[18, 24]], die1: 6, die2: 3, mover: .white, before: b)
        XCTAssertEqual(n.moveText, "7/1^")
        XCTAssertFalse(n.motherPinned)
    }

    // ── Portes ───────────────────────────────────────────────────────────────

    private func portes(white: [Int: Int], black: [Int: Int], whiteBar: Int = 0, blackBar: Int = 0,
                        whiteOff: Int = 0, blackOff: Int = 0) -> GameBoard {
        let b = GameBoard(config: config(GameVariants.portes))
        PortesVariant.setPosition(on: b, white: white, black: black, whiteBar: whiteBar,
                                  blackBar: blackBar, whiteOff: whiteOff, blackOff: blackOff)
        return b
    }

    func testPortesOpeningBothColours() {
        let b = startBoard(GameVariants.portes)
        // White 13/7 8/7 (physical 12→18, 17→18).
        XCTAssertEqual(text([[12, 18], [17, 18]], 6, 1, .white, b), "61: 13/7 8/7")
        // Black 13/7 8/7 (physical: its numbering is the board's).
        XCTAssertEqual(text([[13, 7], [8, 7]], 6, 1, .black, b), "61: 13/7 8/7")
    }

    func testPortesHitChainKeepsTheHitPoint() {
        // Black blot on 18 = White's 7 point.
        let b = portes(white: [12: 5, 1: 10], black: [18: 1, 24: 14])
        XCTAssertEqual(text([[12, 18], [18, 20]], 6, 2, .white, b), "62: 13/7*/5")
        // Without a hit the chain collapses.
        let c = portes(white: [12: 5, 1: 10], black: [24: 15])
        XCTAssertEqual(text([[12, 18], [18, 20]], 6, 2, .white, c), "62: 13/5")
        // Hit on the final landing point.
        XCTAssertEqual(text([[12, 18], [1, 3]], 6, 2, .white, b), "62: 24/22 13/7*")
    }

    func testPortesBlackHitMarksOnlyTheFirstLander() {
        let b = portes(white: [10: 1, 1: 14], black: [13: 5, 11: 2, 24: 8])
        XCTAssertEqual(text([[11, 10], [13, 10]], 3, 1, .black, b), "31: 13/10* 11/10")
    }

    func testPortesBarEntryBothColours() {
        let wb = portes(white: [12: 14], black: [24: 15], whiteBar: 1)
        XCTAssertEqual(text([[0, 3], [12, 16]], 4, 3, .white, wb), "43: bar/22 13/9")
        let bb = portes(white: [1: 15], black: [13: 14], blackBar: 1)
        XCTAssertEqual(text([[25, 22], [13, 9]], 4, 3, .black, bb), "43: bar/22 13/9")
        // Entering onto a blot: bar/22*.
        let hit = portes(white: [12: 14, 22: 1], black: [24: 14], blackBar: 1)
        XCTAssertEqual(text([[25, 22]], 3, 3, .black, hit).hasPrefix("33: bar/22*"), true)
    }

    func testPortesBearOffBothColours() {
        let wb = portes(white: [22: 2, 24: 13], black: [1: 15])
        XCTAssertEqual(text([[22, 25], [24, 25]], 3, 1, .white, wb), "31: 3/off 1/off")
        let bb = portes(white: [24: 15], black: [3: 2, 1: 13])
        XCTAssertEqual(text([[3, 0], [1, 0]], 3, 1, .black, bb), "31: 3/off 1/off")
    }

    func testPortesDoublesGroup() {
        let b = startBoard(GameVariants.portes)
        XCTAssertEqual(text([[12, 16], [12, 16], [1, 5], [1, 5]], 4, 4, .white, b), "44: 24/20(2) 13/9(2)")
        XCTAssertEqual(text([[12, 16], [16, 20], [20, 24]], 4, 4, .white,
                            portes(white: [12: 15], black: [6: 15])), "44: 13/1")
    }

    // ── Fevga ────────────────────────────────────────────────────────────────

    func testFevgaBothColoursFromTheirStart() {
        let b = startBoard(GameVariants.fevga)
        XCTAssertEqual(text([[1, 7]], 6, 6, .white, b), "66: 24/18")
        XCTAssertEqual(text([[13, 19]], 6, 6, .black, b), "66: 24/18")
        XCTAssertEqual(text([[13, 23]], 6, 4, .black, b), "64: 24/14")
    }

    func testFevgaBlackWrapsAndBearsOff() {
        // Black on 23 (path 11 → its 14 point) wraps to 3 (path 15 → its 10 point).
        let b = board(GameVariants.fevga, [23: k(1), 13: k(14), 1: w(15)])
        XCTAssertEqual(text([[23, 3]], 4, 4, .black, b).hasPrefix("44: 14/10"), true)
        // Black's last point is 12 (its 1 point); off is the 0 tray.
        let off = board(GameVariants.fevga, [12: k(2), 7: k(13), 1: w(15)])
        XCTAssertEqual(text([[12, 0], [7, 0]], 6, 1, .black, off), "61: 6/off 1/off")
        // White bears off to 25.
        let woff = board(GameVariants.fevga, [24: w(2), 19: w(13), 13: k(15)])
        XCTAssertEqual(text([[19, 25], [24, 25]], 6, 1, .white, woff), "61: 6/off 1/off")
    }

    func testFevgaHasNoMarks() {
        let b = startBoard(GameVariants.fevga)
        let n = MoveNotation.describe([[1, 7], [1, 5]], die1: 6, die2: 4, mover: .white, before: b)
        XCTAssertTrue(n.segments.allSatisfy { $0.stops.allSatisfy { $0.mark == nil } })
        XCTAssertFalse(n.motherPinned)
    }

    // ── Whole game ───────────────────────────────────────────────────────────

    func testGameReplaysAndAlternatesMovers() {
        let plies = [
            PlyRecord(die1: 6, die2: 4, halfMoves: [[1, 7], [1, 5]]),       // White
            PlyRecord(die1: 3, die2: 1, halfMoves: [[24, 21], [24, 23]]),   // Black
            PlyRecord(die1: 2, die2: 2, halfMoves: []),                     // White passes
            PlyRecord(die1: 2, die2: 1, halfMoves: [[23, 21], [24, 22]]),   // Black
            PlyRecord(die1: 4, die2: 2, halfMoves: [[1, 5], [7, 9]]),       // White
        ]
        let notes = MoveNotation.game(plies, startingPlayer: .white, config: config(GameVariants.plakoto))
        XCTAssertEqual(notes.map(\.text), [
            "64: 24/18 24/20",
            "31: 24/21 24/23",
            "22: No move",
            "21: 24/22 23/21",
            "42: 24/20 18/16",
        ])
        // Same record started by Black flips every mover.
        let blackFirst = [PlyRecord(die1: 6, die2: 4, halfMoves: [[24, 18], [24, 20]])]
        XCTAssertEqual(MoveNotation.game(blackFirst, startingPlayer: .black,
                                         config: config(GameVariants.plakoto)).map(\.text),
                       ["64: 24/18 24/20"])
    }

    func testGamePinThenRelease() {
        // Black leaves a blot on 21; White's 55 lands on it from 24.
        let plies = [
            PlyRecord(die1: 3, die2: 1, halfMoves: [[24, 21], [24, 23]]),   // Black
            PlyRecord(die1: 5, die2: 5, halfMoves: [[1, 6], [6, 11], [11, 16], [16, 21]]),     // White 24/4^
        ]
        let notes = MoveNotation.game(plies, startingPlayer: .black, config: config(GameVariants.plakoto))
        XCTAssertEqual(notes[1].moveText, "24/4^")
    }
}
