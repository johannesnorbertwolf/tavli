import Foundation

/// Mirrors the `unary_v3` path of `ai/board_encoder.py` (the version baked into
/// `gold_v9.pth`). Produces a 486-float vector: 26 points x 18 per-point features
/// (1 color bit + 2 captured bits + 15 unary count) plus 18 hand-crafted globals.
///
/// Perspective-invariant: the current player iterates slots 0->n-1 over board
/// indices, the opponent iterates n-1->0. In flipped (current-player) coordinates
/// slot 0 is the opponent bear-off, slot n-1 is our bear-off.
public struct BoardEncoder {
    public static let smartFeatureCount = 18

    public let boardSize: Int
    public let piecesPerPlayer: Int
    public let homeSize: Int

    private let pointSize: Int
    private let numPoints: Int
    private let rawSize: Int

    public init(config: GameConfig = .standard) {
        self.boardSize = config.boardSize
        self.piecesPerPlayer = config.piecesPerPlayer
        self.homeSize = config.homeSize
        self.pointSize = 3 + config.piecesPerPlayer
        self.numPoints = config.boardSize + 2
        self.rawSize = numPoints * pointSize
    }

    public var inputSize: Int { rawSize + Self.smartFeatureCount }

    public func encode(_ board: GameBoard, isWhitesTurn: Bool) -> [Float] {
        let ps = pointSize
        let bs = boardSize
        let ppp = piecesPerPlayer
        let n = numPoints
        let our: Color = isWhitesTurn ? .white : .black

        let ourHomeLo = bs - homeSize + 1
        let ourHomeHi = bs
        let oppHomeLo = 1
        let oppHomeHi = homeSize
        let lastSlot = n - 1

        var out = [Float](repeating: 0, count: inputSize)

        var ourPip = 0, theirPip = 0
        var ourBlots = 0, theirBlots = 0
        var ourHeld = 0, theirHeld = 0
        var ourPinned = 0, theirPinned = 0
        var ourInOurHome = 0, theirInTheirHome = 0
        var ourInTheirHome = 0, theirInOurHome = 0
        var ourBorne = 0, theirBorne = 0
        var ourRun = 0, ourMaxPrime = 0
        var theirRun = 0, theirMaxPrime = 0

        @inline(__always) func flushRuns() {
            if ourRun > ourMaxPrime { ourMaxPrime = ourRun }
            if theirRun > theirMaxPrime { theirMaxPrime = theirRun }
            ourRun = 0
            theirRun = 0
        }

        for slot in 0..<n {
            let pointIndex = isWhitesTurn ? slot : (n - 1 - slot)
            let point = board.points[pointIndex]

            if point.isEmpty {
                flushRuns()
                continue
            }

            let base = slot * ps
            let isOurs = point.isColor(our)
            let count = point.activeCount
            let capturedByOur = point.isCaptured(by: our)
            let capturedByTheir = capturedByOur ? false : point.isCaptured

            // Per-point raw encoding (unary_v2 layout):
            // [color_bit, captured_by_us, captured_by_them, unary_count...]
            if !isOurs { out[base] = 1 }
            if capturedByOur { out[base + 1] = 1 }
            if capturedByTheir { out[base + 2] = 1 }
            if count > 0 {
                for k in 0..<count { out[base + 3 + k] = 1 }
            }

            let ourCount: Int
            let theirCount: Int
            if capturedByOur {
                ourCount = count; theirCount = 1
            } else if capturedByTheir {
                ourCount = 1; theirCount = count
            } else if isOurs {
                ourCount = count; theirCount = 0
            } else {
                ourCount = 0; theirCount = count
            }

            if slot == 0 {
                theirBorne += theirCount
                ourBorne += ourCount
                flushRuns()
                continue
            }
            if slot == lastSlot {
                ourBorne += ourCount
                theirBorne += theirCount
                flushRuns()
                continue
            }

            ourPip += ourCount * (lastSlot - slot)
            theirPip += theirCount * slot

            if isOurs && !capturedByTheir && count == 1 {
                ourBlots += 1
            } else if !isOurs && !capturedByOur && count == 1 {
                theirBlots += 1
            }

            if isOurs && count >= 2 {
                ourHeld += 1
                ourRun += 1
                if theirRun > theirMaxPrime { theirMaxPrime = theirRun }
                theirRun = 0
            } else if !isOurs && count >= 2 {
                theirHeld += 1
                theirRun += 1
                if ourRun > ourMaxPrime { ourMaxPrime = ourRun }
                ourRun = 0
            } else {
                flushRuns()
            }

            if capturedByOur { theirPinned += 1 }
            if capturedByTheir { ourPinned += 1 }

            if ourHomeLo <= slot && slot <= ourHomeHi {
                ourInOurHome += ourCount
                theirInOurHome += theirCount
            } else if oppHomeLo <= slot && slot <= oppHomeHi {
                theirInTheirHome += theirCount
                ourInTheirHome += ourCount
            }
        }

        flushRuns()

        let invPip = 1.0 / Float(ppp * bs)
        let invPpp = 1.0 / Float(ppp)
        let invHome = 1.0 / Float(homeSize)
        let s = rawSize
        out[s + 0] = Float(ourPip) * invPip
        out[s + 1] = Float(theirPip) * invPip
        out[s + 2] = Float(ourBlots) * invPpp
        out[s + 3] = Float(theirBlots) * invPpp
        out[s + 4] = Float(ourHeld) * invPpp
        out[s + 5] = Float(theirHeld) * invPpp
        out[s + 6] = Float(ourPinned) * invPpp
        out[s + 7] = Float(theirPinned) * invPpp
        out[s + 8] = Float(ourInOurHome) * invPpp
        out[s + 9] = Float(theirInTheirHome) * invPpp
        out[s + 10] = Float(ourInTheirHome) * invPpp
        out[s + 11] = Float(theirInOurHome) * invPpp
        out[s + 12] = Float(ourBorne) * invPpp
        out[s + 13] = Float(theirBorne) * invPpp
        out[s + 14] = Float(ourMaxPrime) * invHome
        out[s + 15] = Float(theirMaxPrime) * invHome
        out[s + 16] = Float(ourPip - theirPip) * invPip
        out[s + 17] = Float(ourBorne - theirBorne) * invPpp

        return out
    }
}
