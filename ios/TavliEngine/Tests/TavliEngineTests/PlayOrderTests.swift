import XCTest
@testable import TavliEngine

/// #169 follow-up — `MoveBuilder` accepts a legal move's half-moves only in an order
/// that is itself a legal sequence of plays (`GameVariant.isLegalStep` per step), not
/// in any order the bag allows: Portes bar-first, bear-off only once every checker is
/// home, standard Plakoto's larger-die bear-off from the rearmost point, Fevga's
/// first-checker lock.
final class PlayOrderTests: XCTestCase {

    private func builder(_ v: any GameVariant, _ board: GameBoard, _ color: Color,
                         _ d1: Int, _ d2: Int) -> (MoveBuilder, [Move]) {
        let dice = Dice(); dice.set(d1, d2)
        let legal = v.legalMoves(on: board, color: color, dice: dice)
        return (MoveBuilder(legalMoves: legal, board: board, die1: d1, die2: d2), legal)
    }

    private func play(_ b: MoveBuilder, _ board: GameBoard, _ from: Int, _ to: Int, _ color: Color = .white) {
        let hm = HalfMove(from: board.points[from], to: board.points[to], color: color)
        board.variant.applyHalfMove(hm, on: board)
        b.commit(halfMove: hm)
    }

    private func pairs(_ moves: [Move]) -> Set<[[Int]]> {
        Set(moves.map { $0.halfMoves.map { [$0.from.position, $0.to.position] } })
    }

    // ── Portes: bar first ─────────────────────────────────────────────────────

    /// A checker on the bar must enter before any other checker moves — even though
    /// the legal move `[0→2, 5→8]` contains a half (`5→8`) another order would allow.
    func testPortesOnlyBarEntriesWhileOnTheBar() {
        let v = GameVariants.portes
        let board = GameBoard(config: GameConfig(variant: v))
        PortesVariant.setPosition(on: board, white: [5: 1, 24: 13], black: [1: 15], whiteBar: 1)
        let (b, legal) = builder(v, board, .white, 2, 3)
        XCTAssertTrue(pairs(legal).contains([[0, 2], [5, 8]]))
        XCTAssertEqual(b.selectableSourcePoints, [0])
        XCTAssertTrue(b.validDestinations(for: 5).isEmpty)
        play(b, board, 0, 2)
        XCTAssertTrue(b.selectableSourcePoints.contains(5), "after entering, the other checker may move")
        XCTAssertTrue(b.validDestinations(for: 5).contains(8))
    }

    /// Two checkers on the bar, both dice enterable: the second entry comes before the
    /// entered checker may continue.
    func testPortesTwoOnTheBarEnterBothFirst() {
        let v = GameVariants.portes
        let board = GameBoard(config: GameConfig(variant: v))
        PortesVariant.setPosition(on: board, white: [24: 13], black: [1: 15], whiteBar: 2)
        let (b, _) = builder(v, board, .white, 3, 4)
        XCTAssertEqual(b.selectableSourcePoints, [0])
        XCTAssertEqual(b.validDestinations(for: 0), [3, 4], "no 0→3→7 chain while a second checker waits")
        play(b, board, 0, 3)
        XCTAssertEqual(b.selectableSourcePoints, [0], "the entered checker waits for the other entry")
        XCTAssertEqual(b.validDestinations(for: 0), [4])
        play(b, board, 0, 4)
        XCTAssertNotNil(b.completedMove)
    }

    /// Two on the bar, only one die enterable (5 is a made point): one entry, then the
    /// turn ends — nothing else is ever offered.
    func testPortesTwoOnTheBarOneEnterableDie() {
        let v = GameVariants.portes
        let board = GameBoard(config: GameConfig(variant: v))
        PortesVariant.setPosition(on: board, white: [10: 1, 24: 12], black: [5: 2, 1: 13], whiteBar: 2)
        let (b, legal) = builder(v, board, .white, 3, 5)
        XCTAssertEqual(pairs(legal), [[[0, 3]]])
        XCTAssertEqual(b.selectableSourcePoints, [0])
        XCTAssertEqual(b.validDestinations(for: 0), [3])
        play(b, board, 0, 3)
        XCTAssertNotNil(b.completedMove)
        XCTAssertTrue(b.selectableSourcePoints.isEmpty)
    }

    /// No entry possible at all: a forced pass, as before.
    func testPortesBlockedBarPasses() {
        let v = GameVariants.portes
        let board = GameBoard(config: GameConfig(variant: v))
        PortesVariant.setPosition(on: board, white: [10: 1, 24: 13], black: [3: 2, 5: 2, 1: 11], whiteBar: 1)
        let dice = Dice(); dice.set(3, 5)
        XCTAssertTrue(v.legalMoves(on: board, color: .white, dice: dice).isEmpty)
    }

    // ── Bear-off only once every checker is home ──────────────────────────────

    /// Plakoto: `{18→19, 22→25}` is legal, but the bear-off only after 18→19 brings the
    /// last checker home.
    func testPlakotoBearOffWaitsForLastCheckerHome() {
        let v = GameVariants.plakoto
        let board = GameBoard(config: GameConfig(variant: v))
        board.clear()
        board.setPoint(18, pieces: [.white])
        board.setPoint(22, pieces: [.white])
        board.setPoint(20, pieces: Array(repeating: .white, count: 13))
        board.setPoint(1, pieces: Array(repeating: .black, count: 15))
        let (b, legal) = builder(v, board, .white, 3, 1)
        XCTAssertTrue(pairs(legal).contains([[22, 25], [18, 19]]), "canonical order lists the bear-off first")
        XCTAssertFalse(b.validDestinations(for: 22).contains(25))
        play(b, board, 18, 19)
        XCTAssertTrue(b.validDestinations(for: 22).contains(25))
    }

    func testPortesBearOffWaitsForLastCheckerHome() {
        let v = GameVariants.portes
        let board = GameBoard(config: GameConfig(variant: v))
        PortesVariant.setPosition(on: board, white: [18: 1, 22: 1, 20: 13], black: [1: 15])
        let (b, legal) = builder(v, board, .white, 1, 3)
        XCTAssertTrue(legal.contains { m in m.halfMoves.contains { $0.to.position == 25 } })
        XCTAssertFalse(b.validDestinations(for: 22).contains(25))
        play(b, board, 18, 19)
        XCTAssertTrue(b.validDestinations(for: 22).contains(25))
    }

    // ── Standard Plakoto: larger-die bear-off from the rearmost point ──────────

    /// `{20→24, 22→off(6)}`: the 6 bears 22 off only once 20 has moved past it.
    func testStandardPlakotoLargerDieBearOffOrder() {
        let v = GameVariants.plakotoStandard
        let board = GameBoard(config: GameConfig(variant: v))
        board.clear()
        board.setPoint(20, pieces: [.white])
        board.setPoint(22, pieces: [.white])
        board.setPoint(25, pieces: Array(repeating: .white, count: 13))
        board.setPoint(6, pieces: Array(repeating: .black, count: 15))
        let (b, legal) = builder(v, board, .white, 4, 6)
        XCTAssertTrue(pairs(legal).contains([[20, 24], [22, 25]]))
        XCTAssertFalse(b.validDestinations(for: 22).contains(25), "20 still behind 22")
        play(b, board, 20, 24)
        XCTAssertTrue(b.validDestinations(for: 22).contains(25))
    }

    // ── Fevga: first-checker lock ─────────────────────────────────────────────

    /// From the start only one checker may leave; after it moves, only it continues.
    func testFevgaFirstCheckerLockStepByStep() {
        let v = GameVariants.fevga
        let game = Game(config: GameConfig(variant: v), startingPlayer: .white)
        let board = game.board
        let (b, _) = builder(v, board, .white, 3, 5)
        let start = b.selectableSourcePoints
        XCTAssertEqual(start.count, 1)
        let src = start.first!
        let first = b.validDestinations(for: src).filter { abs($0 - src) == 3 }.first!
        play(b, board, src, first)
        XCTAssertEqual(b.selectableSourcePoints, [first], "the start checkers stay locked")
    }

    // ── Randomized: every builder-reachable prefix is a legal play order ──────

    /// Random games for every variant, each turn composed by a random walk through the
    /// builder (single steps and far gestures alike). Each step is checked against an
    /// independent statement of the ordering rules at the position it is played, the
    /// builder never strands a prefix, and every finished turn is a legal move's result.
    func testRandomBuilderWalksFollowLegalPlayOrder() {
        for v in GameVariants.all {
            var rng = SplitMix64(seed: 0x0D3E5)
            for _ in 0..<3 {
                let game = Game(config: GameConfig(variant: v), startingPlayer: .white)
                var plies = 0
                while !game.isOver() && plies < 2000 {
                    plies += 1
                    let d1 = Int.random(in: 1...6, using: &rng), d2 = Int.random(in: 1...6, using: &rng)
                    game.dice.set(d1, d2)
                    let color = game.currentPlayer
                    let board = game.board
                    let legal = v.legalMoves(on: board, color: color, dice: game.dice)
                    if !legal.isEmpty {
                        var results = Set<[[Color]]>()
                        for m in legal { v.apply(m, on: board); results.insert(board.captureStacks()); v.undo(m, on: board) }
                        let b = MoveBuilder(legalMoves: legal, board: board, die1: d1, die2: d2)
                        var steps = 0
                        while b.completedMove == nil || (!b.selectableSourcePoints.isEmpty && Bool.random(using: &rng)) {
                            steps += 1
                            guard steps < 10 else { XCTFail("\(v.id): runaway walk"); return }
                            let sources = b.selectableSourcePoints.sorted()
                            guard !sources.isEmpty else {
                                XCTFail("\(v.id): stranded prefix \(b.built) for dice \(d1)-\(d2)"); return
                            }
                            let src = sources[Int.random(in: 0..<sources.count, using: &rng)]
                            let dests = b.validDestinations(for: src).sorted()
                            let dst = dests[Int.random(in: 0..<dests.count, using: &rng)]
                            let options = b.routeOptions(from: src, to: dst)
                            let route = options[Int.random(in: 0..<options.count, using: &rng)]
                            var applied: [HalfMove] = []
                            for hop in route {
                                assertLegalOrder(v, board, color, from: hop.from.position, to: hop.to.position,
                                                 dice: [d1, d2])
                                let hm = HalfMove(from: board.points[hop.from.position],
                                                  to: board.points[hop.to.position], color: color)
                                v.applyHalfMove(hm, on: board)
                                applied.append(hm)
                            }
                            b.commit(halfMoves: applied)
                        }
                        XCTAssertTrue(results.contains(board.captureStacks()), "\(v.id): composed an illegal result")
                    }
                    game.switchTurn()
                }
            }
        }
    }

    /// An independent restatement of the per-play ordering rules (not `isLegalStep`).
    private func assertLegalOrder(_ v: any GameVariant, _ board: GameBoard, _ color: Color,
                                  from: Int, to: Int, dice: [Int], file: StaticString = #filePath, line: UInt = #line) {
        let n = board.boardSize
        let path = { (p: Int) in v.pathIndex(of: p, for: color, boardSize: n) }
        // Portes: bar first.
        if v.id == "portes", PortesVariant.barCount(color, on: board) > 0 {
            XCTAssertEqual(path(from), 0, "portes: moved \(from)→\(to) with a checker on the bar", file: file, line: line)
        }
        guard to == v.bearOffPoint(for: color, boardSize: n) else {
            // Fevga: while no checker has reached the unlock point (and none is off),
            // a second checker may not leave the start.
            if v.id == "fevga" {
                let own = (1...n).filter { board.points[$0].topColor == color }
                let unlocked = own.contains { path($0) >= 14 }
                    || board.points[v.bearOffPoint(for: color, boardSize: n)].countForColor(color) > 0
                let startPt = v.point(atPath: 1, for: color, boardSize: n)
                if !unlocked && board.points[startPt].count < board.numberOfPieces && board.points[startPt].topColor == color {
                    XCTAssertNotEqual(from, startPt, "fevga: a second checker left the start", file: file, line: line)
                }
            }
            return
        }
        // Bear-off: every own checker home (path ≥ n-5), bar included.
        var outside = 0
        for i in 0...(n + 1) where i != to {
            let c = board.points[i].countForColor(color)
            if c > 0 && path(i) < n - 5 { outside += c }
        }
        XCTAssertEqual(outside, 0, "\(v.id): bore off \(from) with \(outside) checker(s) outside home", file: file, line: line)
        // A die larger than needed only from the rearmost occupied home point.
        let need = n + 1 - path(from)
        if !dice.contains(need) {
            let behind = (1...n).contains { i in
                i != from && board.points[i].countForColor(color) > 0 && path(i) < path(from)
            }
            XCTAssertFalse(behind, "\(v.id): larger-die bear-off from \(from) with a checker behind", file: file, line: line)
        }
    }
}
