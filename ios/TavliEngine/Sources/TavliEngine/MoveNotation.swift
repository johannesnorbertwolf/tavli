import Foundation

/// Readable, backgammon-style notation for one turn (#178), shared by the move history,
/// the post-game review and the drill. Pure: built from a ply's dice + recorded
/// `[from, to]` pairs and the position **before** the move (which it copies, never
/// mutates), so hits, pins and bear-offs are derived by replaying the pairs.
///
/// **Rules.**
/// - Points are numbered 1…24 **from the mover's side**: `boardSize + 1 − pathIndex`,
///   via the variant's path order (so Fevga's wrapped Black path works). Path index 0
///   (a Portes bar) is `bar`, the bear-off tray is `off`.
/// - One segment per checker, `from/to`: consecutive hops of the same checker are
///   chained (`13/5`), keeping an intermediate point only when it was a hit
///   (`13/7*/5`, Portes keeps one half per die). Identical segments group as `6/4(3)`.
///   Segments are ordered highest point first.
/// - Marks: `*` = a hit (Portes), `^` = a new pin (Plakoto house + standard), placed on
///   the first segment landing on that point. `motherPinned` = this move pinned the
///   opponent's mother (standard Plakoto), which decides the game. Fevga has no marks.
/// - Dice are high die first (`64`); no legal move = no segments (`noMove`).
public struct MoveNotation: Equatable, Sendable {
    /// A place a checker leaves from or lands on, numbered from the mover's side.
    public enum Place: Equatable, Hashable, Sendable {
        case point(Int)
        case bar
        case off

        /// `13`, `bar`, `off` — notation tokens, never translated.
        public var text: String {
            switch self {
            case .point(let n): return "\(n)"
            case .bar: return "bar"
            case .off: return "off"
            }
        }

        /// Sort key: bar above every point, off below.
        var rank: Int {
            switch self {
            case .bar: return 25
            case .point(let n): return n
            case .off: return 0
            }
        }
    }

    public enum Mark: Equatable, Sendable {
        /// Hit a blot (Portes): `*`.
        case hit
        /// Pinned an opponent checker (Plakoto): `^`.
        case pin

        public var symbol: String { self == .hit ? "*" : "^" }
    }

    /// One point a checker reaches; the last stop of a segment is its landing point.
    public struct Stop: Equatable, Sendable {
        public let place: Place
        public var mark: Mark?

        public init(place: Place, mark: Mark? = nil) {
            self.place = place
            self.mark = mark
        }
    }

    /// One checker's path this turn (`count` identical paths grouped).
    public struct Segment: Equatable, Sendable {
        public let from: Place
        /// At least one; intermediate stops appear only when marked (a hit).
        public var stops: [Stop]
        public var count: Int

        public init(from: Place, stops: [Stop], count: Int = 1) {
            self.from = from
            self.stops = stops
            self.count = count
        }

        public var to: Place { stops.last?.place ?? from }
        /// Mark on the landing point.
        public var mark: Mark? { stops.last?.mark }

        /// `13/7*/5`, `6/4^(2)`.
        public var text: String {
            var s = from.text
            for stop in stops { s += "/" + stop.place.text + (stop.mark?.symbol ?? "") }
            if count > 1 { s += "(\(count))" }
            return s
        }
    }

    /// The higher die (shown first).
    public let highDie: Int
    /// The lower die (equal to `highDie` on a double).
    public let lowDie: Int
    public let segments: [Segment]
    /// This move pinned the opponent's mother checker (standard Plakoto only).
    public let motherPinned: Bool

    public init(highDie: Int, lowDie: Int, segments: [Segment], motherPinned: Bool = false) {
        self.highDie = highDie
        self.lowDie = lowDie
        self.segments = segments
        self.motherPinned = motherPinned
    }

    /// No legal move was played (a pass).
    public var noMove: Bool { segments.isEmpty }
    /// `64`.
    public var diceText: String { "\(highDie)\(lowDie)" }
    /// `13/7^ 8/4`, or `No move` (plain-text English; the app localizes the phrase).
    public var moveText: String {
        noMove ? "No move" : segments.map(\.text).joined(separator: " ")
    }
    /// `64: 13/7^ 8/4`, with ` (mother pinned)` when it applies.
    public var text: String {
        "\(diceText): \(moveText)" + (motherPinned ? " (mother pinned)" : "")
    }

    // ── Building ─────────────────────────────────────────────────────────────

    /// Notation for `pairs` played by `mover` with `die1`/`die2` from the position
    /// `before` (left untouched).
    public static func describe(_ pairs: [[Int]], die1: Int, die2: Int, mover: Color,
                                before: GameBoard) -> MoveNotation {
        describe(pairs, die1: die1, die2: die2, mover: mover,
                 stacks: before.captureStacks(), config: before.config)
    }

    /// Notation for `pairs` from a position given as per-point stacks (bottom → top),
    /// e.g. `PlyEvaluation.boardStacks`.
    public static func describe(_ pairs: [[Int]], die1: Int, die2: Int, mover: Color,
                                stacks: [[Color]], config: GameConfig) -> MoveNotation {
        let board = GameBoard(config: config)
        for (i, pieces) in stacks.enumerated() where i < board.points.count {
            board.points[i].pieces = pieces
        }
        return play(pairs, die1: die1, die2: die2, mover: mover, on: board)
    }

    /// Notation for every ply of a game, replayed from the variant's starting position
    /// (movers alternate from `startingPlayer`, as `GameSession.replay` does).
    /// `handicap` (#148) adds a head-start game's advanced checkers to the start.
    public static func game(_ plies: [PlyRecord], startingPlayer: Color,
                            config: GameConfig, handicap: HandicapSetup? = nil) -> [MoveNotation] {
        let board = GameBoard(config: config)
        if let handicap {
            handicap.setUpInitialPosition(on: board)
        } else {
            config.variant.setUpInitialPosition(on: board)
        }
        var mover = startingPlayer
        var out: [MoveNotation] = []
        out.reserveCapacity(plies.count)
        for ply in plies {
            out.append(play(ply.halfMoves, die1: ply.die1, die2: ply.die2, mover: mover, on: board))
            mover = mover.opponent
        }
        return out
    }

    /// Format and apply `pairs` on `board` (mutated: left at the post-move position).
    private static func play(_ pairs: [[Int]], die1: Int, die2: Int, mover: Color,
                             on board: GameBoard) -> MoveNotation {
        let variant = board.variant
        let n = board.boardSize
        let upper = n + 1
        let opponent = mover.opponent
        let isPortes = variant is PortesVariant
        let isFevga = variant is FevgaVariant
        let standard = variant as? StandardPlakotoVariant
        let motherBefore = standard?.motherPinned(opponent, board) ?? false
        let pinnedBefore = Set((1...n).filter { board.points[$0].isCaptured(by: mover) })

        func place(_ index: Int) -> Place {
            let num = upper - variant.pathIndex(of: index, for: mover, boardSize: n)
            if num >= upper { return .bar }
            if num <= 0 { return .off }
            return .point(num)
        }

        // Chain each half onto the segment whose checker just arrived at its source.
        // Raw board indices: `from` index + stops (index, hit).
        struct Raw { let from: Int; var stops: [(index: Int, hit: Bool)] }
        var raws: [Raw] = []
        let offIndex = variant.bearOffPoint(for: mover, boardSize: n)
        for pair in pairs where pair.count == 2 {
            let from = pair[0], to = pair[1]
            guard (0...upper).contains(from), (0...upper).contains(to) else { continue }
            let target = board.points[to]
            let oppBefore = to == offIndex ? 0 : target.countForColor(opponent)
            variant.applyHalfMove(HalfMove(from: board.points[from], to: target, color: mover), on: board)
            let hit = !isFevga && oppBefore > 0 && to != offIndex
                && (1...n).contains(to) && board.points[to].countForColor(opponent) == 0
            if from != offIndex,
               let k = raws.lastIndex(where: { $0.stops.last?.index == from && $0.stops.last?.index != offIndex }) {
                raws[k].stops.append((to, hit))
            } else {
                raws.append(Raw(from: from, stops: [(to, hit)]))
            }
        }

        // Landing pins = points the mover newly pins in the final position.
        let newPins: Set<Int> = isPortes || isFevga ? [] : Set((1...n).filter {
            board.points[$0].isCaptured(by: mover) && !pinnedBefore.contains($0)
        })
        let motherPinned = !motherBefore && (standard?.motherPinned(opponent, board) ?? false)

        var segments: [Segment] = raws.map { raw in
            var stops: [Stop] = []
            for (i, s) in raw.stops.enumerated() {
                let last = i == raw.stops.count - 1
                if last {
                    let mark: Mark? = s.hit ? .hit : (newPins.contains(s.index) ? .pin : nil)
                    stops.append(Stop(place: place(s.index), mark: mark))
                } else if s.hit {
                    stops.append(Stop(place: place(s.index), mark: .hit))
                }
            }
            return Segment(from: place(raw.from), stops: stops)
        }

        // Highest point first (then the farther-travelled checker first).
        segments.sort { a, b in
            a.from.rank != b.from.rank ? a.from.rank > b.from.rank : a.to.rank < b.to.rank
        }

        // A landing mark belongs to the first segment (in display order) landing there.
        var landingMark: [Place: Mark] = [:]
        for seg in segments { if let m = seg.mark, landingMark[seg.to] == nil { landingMark[seg.to] = m } }
        var landed = Set<Place>()
        for i in segments.indices {
            let to = segments[i].to
            segments[i].stops[segments[i].stops.count - 1].mark =
                landed.insert(to).inserted ? landingMark[to] : nil
        }

        // Group identical paths (marks merged): `6/4(3)`.
        var grouped: [Segment] = []
        for seg in segments {
            if let k = grouped.firstIndex(where: {
                $0.from == seg.from && $0.stops.map(\.place) == seg.stops.map(\.place)
            }) {
                grouped[k].count += 1
                for (i, stop) in seg.stops.enumerated() where grouped[k].stops[i].mark == nil {
                    grouped[k].stops[i].mark = stop.mark
                }
            } else {
                grouped.append(seg)
            }
        }

        return MoveNotation(highDie: max(die1, die2), lowDie: min(die1, die2),
                            segments: grouped, motherPinned: motherPinned)
    }
}
