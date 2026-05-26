import Foundation

/// Mirrors `PaschGenerator` in `domain/possible_moves.py` — doubles (1-4 equal
/// half-moves). `openPoints` is snapshotted at construction and not updated as the
/// simulation moves checkers, exactly as in Python; only `movablePieces` is mutated.
public struct PaschGenerator {
    private let board: GameBoard
    private let color: Color
    private let boardSize: Int
    private let dieValue: Int
    private let firstPossibleStart: Int
    private let lastPossibleStart: Int   // exclusive (Python range upper bound)
    private let direction: Int
    private let dieWithDirection: Int
    private var movablePieces: [Int]
    private let openPoints: [Bool]
    private let outsideHomeCount: Int

    public init(board: GameBoard, color: Color, die: Die) {
        self.board = board
        self.color = color
        self.boardSize = board.boardSize
        self.dieValue = die.value
        if color.isWhite {
            firstPossibleStart = 1
            lastPossibleStart = boardSize - die.value + 2
            direction = 1
        } else {
            firstPossibleStart = boardSize
            lastPossibleStart = die.value - 1
            direction = -1
        }
        dieWithDirection = dieValue * direction
        movablePieces = (0...(boardSize + 1)).map { board.points[$0].movablePieces(for: color) }
        openPoints = (0...(boardSize + 1)).map { board.points[$0].isOpen(for: color) }
        outsideHomeCount = board.countCheckersOutsideHome(color)
    }

    private func isOffBoard(_ index: Int) -> Bool { index == 0 || index == boardSize + 1 }

    private func canMoveFrom(_ index: Int, _ outsideHomeCount: Int) -> Bool {
        let destination = index + dieWithDirection
        if isOffBoard(destination) && outsideHomeCount > 0 { return false }
        return movablePieces[index] > 0 && openPoints[destination]
    }

    private func outsideHomeDelta(_ fromIndex: Int) -> Int {
        let toIndex = fromIndex + dieWithDirection
        if board.isHomePoint(color, fromIndex) { return 0 }
        if board.isHomePoint(color, toIndex) || isOffBoard(toIndex) { return -1 }
        return 0
    }

    private func makeMove(_ starts: [Int]) -> Move {
        Move(starts.map { HalfMove(from: board.points[$0], to: board.points[$0 + dieWithDirection], color: color) })
    }

    public mutating func findMoves() -> [Move] {
        var possible: [Move] = []
        var secondIsPossible = false
        var thirdIsPossible = false
        var fourthIsPossible = false

        var first = firstPossibleStart
        while first != lastPossibleStart {
            defer { first += direction }
            if !canMoveFrom(first, outsideHomeCount) { continue }
            let outsideAfterFirst = outsideHomeCount + outsideHomeDelta(first)
            movablePieces[first] -= 1
            movablePieces[first + dieWithDirection] += 1

            var second = first
            while second != lastPossibleStart {
                defer { second += direction }
                if !canMoveFrom(second, outsideAfterFirst) { continue }
                secondIsPossible = true
                let outsideAfterSecond = outsideAfterFirst + outsideHomeDelta(second)
                movablePieces[second] -= 1
                movablePieces[second + dieWithDirection] += 1

                var third = second
                while third != lastPossibleStart {
                    defer { third += direction }
                    if !canMoveFrom(third, outsideAfterSecond) { continue }
                    thirdIsPossible = true
                    let outsideAfterThird = outsideAfterSecond + outsideHomeDelta(third)
                    movablePieces[third] -= 1
                    movablePieces[third + dieWithDirection] += 1

                    var fourth = third
                    while fourth != lastPossibleStart {
                        defer { fourth += direction }
                        if !canMoveFrom(fourth, outsideAfterThird) { continue }
                        fourthIsPossible = true
                        possible.append(makeMove([first, second, third, fourth]))
                    }
                    if !fourthIsPossible {
                        possible.append(makeMove([first, second, third]))
                    }
                    movablePieces[third] += 1
                    movablePieces[third + dieWithDirection] -= 1
                }
                if !thirdIsPossible {
                    possible.append(makeMove([first, second]))
                }
                movablePieces[second] += 1
                movablePieces[second + dieWithDirection] -= 1
            }
            if !secondIsPossible {
                possible.append(makeMove([first]))
            }
            movablePieces[first] += 1
            movablePieces[first + dieWithDirection] -= 1
        }
        return possible
    }
}

/// Mirrors `PossibleMoves` in `domain/possible_moves.py`.
public struct PossibleMoves {
    private let board: GameBoard
    private let color: Color
    private let dice: Dice

    public init(board: GameBoard, color: Color, dice: Dice) {
        self.board = board
        self.color = color
        self.dice = dice
    }

    public func findMoves() -> [Move] {
        var possible: [Move] = []
        let outsideHomeCount = board.countCheckersOutsideHome(color)

        if dice.isPasch {
            var gen = PaschGenerator(board: board, color: color, die: dice.die1)
            return gen.findMoves()
        }

        let halfMoves1 = generateHalfMoves(dice.die1.value)
        let halfMoves2 = generateHalfMoves(dice.die2.value)

        for hm1 in halfMoves1 where hm1.isValid() {
            for hm2 in halfMoves2 where hm2.isValid() {
                if hm1.canMergeOrViceVersa(with: hm2) { continue }
                if !isTwoHalfMoveSequenceLegal(hm1, hm2, outsideHomeCount) { continue }
                if hm1.from == hm2.from {
                    if hm1.twoCheckersAvailable() {
                        possible.append(Move([hm1, hm2]))
                    }
                    continue
                }
                possible.append(Move([hm1, hm2]))
            }
        }

        let mergedHalfMoves = generateHalfMoves(dice.die1.value + dice.die2.value)
        for hm in mergedHalfMoves where hm.isValid() {
            let mid1 = color.isWhite ? hm.from.position + dice.die1.value : hm.from.position - dice.die1.value
            let mid2 = color.isWhite ? hm.from.position + dice.die2.value : hm.from.position - dice.die2.value
            let middle1 = board.points[mid1]
            let middle2 = board.points[mid2]
            if !(middle1.isOpen(for: color) || middle2.isOpen(for: color)) { continue }
            if !isMergedHalfMoveLegalWithHomeRule(hm, outsideHomeCount, mid1, mid2) { continue }
            possible.append(Move([hm]))
        }

        emitSingleDieMoves(&possible, halfMoves1, dice.die2.value, outsideHomeCount)
        emitSingleDieMoves(&possible, halfMoves2, dice.die1.value, outsideHomeCount)

        return possible
    }

    /// Emit a single-die move when playing that die leaves the other die unplayable
    /// (the player chooses which die to play; if it blocks the other, the turn ends
    /// with one die played). Mirrors `_emit_single_die_moves`.
    private func emitSingleDieMoves(
        _ possible: inout [Move],
        _ halfMoves: [HalfMove],
        _ otherDieValue: Int,
        _ outsideHomeCount: Int
    ) {
        for hm in halfMoves where hm.isValid() {
            if !isHalfMoveLegalWithHomeRule(hm, outsideHomeCount) { continue }
            board.applyHalfMove(hm)
            let newOutside = outsideHomeCount + outsideHomeDelta(hm)
            let otherHalfMoves = generateHalfMoves(otherDieValue)
            let hasLegalOther = otherHalfMoves.contains { other in
                other.isValid() && isHalfMoveLegalWithHomeRule(other, newOutside)
            }
            board.undoHalfMove(hm)
            if !hasLegalOther {
                possible.append(Move([hm]))
            }
        }
    }

    private func generateHalfMoves(_ dieValue: Int) -> [HalfMove] {
        fromRange(dieValue).map { createHalfMove($0, dieValue) }
    }

    private func fromRange(_ dieValue: Int) -> [Int] {
        if color.isWhite {
            return Array(1..<(board.boardSize + 2 - dieValue))
        }
        return Array((0 + dieValue)..<(board.boardSize + 1))
    }

    private func createHalfMove(_ fromIndex: Int, _ dieValue: Int) -> HalfMove {
        let toIndex = color.isWhite ? fromIndex + dieValue : fromIndex - dieValue
        return HalfMove(from: board.points[fromIndex], to: board.points[toIndex], color: color)
    }

    private func isBearOffMove(_ hm: HalfMove) -> Bool {
        let dest = hm.to.position
        return dest == 0 || dest == board.boardSize + 1
    }

    private func isOffBoardPosition(_ position: Int) -> Bool {
        position == 0 || position == board.boardSize + 1
    }

    private func outsideHomeDelta(_ hm: HalfMove) -> Int {
        let from = hm.from.position
        let to = hm.to.position
        if board.isHomePoint(color, from) { return 0 }
        if board.isHomePoint(color, to) || isOffBoardPosition(to) { return -1 }
        return 0
    }

    private func isHalfMoveLegalWithHomeRule(_ hm: HalfMove, _ outsideHomeCount: Int) -> Bool {
        !isBearOffMove(hm) || outsideHomeCount == 0
    }

    private func isTwoHalfMoveSequenceLegal(_ first: HalfMove, _ second: HalfMove, _ outsideHomeCount: Int) -> Bool {
        isSequenceLegalInOrder(first, second, outsideHomeCount)
            || isSequenceLegalInOrder(second, first, outsideHomeCount)
    }

    private func isSequenceLegalInOrder(_ first: HalfMove, _ second: HalfMove, _ outsideHomeCount: Int) -> Bool {
        if !isHalfMoveLegalWithHomeRule(first, outsideHomeCount) { return false }
        let updated = outsideHomeCount + outsideHomeDelta(first)
        return isHalfMoveLegalWithHomeRule(second, updated)
    }

    private func isMergedHalfMoveLegalWithHomeRule(
        _ merged: HalfMove,
        _ outsideHomeCount: Int,
        _ mid1: Int,
        _ mid2: Int
    ) -> Bool {
        if !isBearOffMove(merged) { return true }
        if outsideHomeCount == 0 { return true }
        let from = merged.from.position
        let to = merged.to.position
        if isSequenceLegalByPositions(from, mid1, to, outsideHomeCount) { return true }
        return isSequenceLegalByPositions(from, mid2, to, outsideHomeCount)
    }

    private func isSequenceLegalByPositions(_ from: Int, _ mid: Int, _ to: Int, _ outsideHomeCount: Int) -> Bool {
        let first = HalfMove(from: board.points[from], to: board.points[mid], color: color)
        let second = HalfMove(from: board.points[mid], to: board.points[to], color: color)
        return isSequenceLegalInOrder(first, second, outsideHomeCount)
    }
}
