import Foundation
import XCTest
import CoreML
@testable import TavliEngine

/// Guards against the post-game analysis holding on to per-inference memory until it
/// finishes. On an iPhone 13 mini a full review grew the app past its 2 GB jetsam limit
/// and iOS killed it mid-drill: every `MLModel.prediction` hands back autoreleased
/// Objective-C objects, and the whole analysis ran as one long synchronous job with no
/// autorelease pool in between, so nothing was freed until it returned.
///
/// Runs the analysis the way the app does — on a detached task, off the main thread —
/// and checks the process footprint grows by far less than the leak produced.
final class AnalysisMemoryTests: XCTestCase {

    /// Current physical footprint (what jetsam measures) in MB.
    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    private struct LCG: RandomNumberGenerator {
        var state: UInt64
        init(_ seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// A deterministic game (first legal move each ply), cut at `maxPlies`.
    private static func playOut(config: GameConfig, seed: UInt64, maxPlies: Int) -> GameRecord {
        let board = GameBoard(config: config)
        board.initializeBoard()
        let dice = Dice(numberOfSides: config.dieSides)
        var rng = LCG(seed)
        var plies: [PlyRecord] = []
        var mover: Color = .white
        while plies.count < maxPlies {
            let d1 = Int.random(in: 1...config.dieSides, using: &rng)
            let d2 = Int.random(in: 1...config.dieSides, using: &rng)
            dice.set(d1, d2)
            let legal = PossibleMoves(board: board, color: mover, dice: dice).findMoves()
            let chosen = legal.first.map { $0.halfMoves.map { [$0.from.position, $0.to.position] } } ?? []
            plies.append(PlyRecord(die1: d1, die2: d2, halfMoves: chosen))
            for pair in chosen where pair.count == 2 {
                board.points[pair[0]].pop()
                board.points[pair[1]].push(mover)
            }
            if board.hasWon(mover) { break }
            mover = mover.opponent
        }
        return GameRecord(startingPlayer: .white, aiColor: .black, plies: plies)
    }

    func testProgressiveAnalysisDoesNotAccumulateMemory() async throws {
        let fixtures = try FixtureLoader.load()
        let config = gameConfig(fixtures.config)
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: "PlakotoValue", withExtension: "mlpackage", subdirectory: "Fixtures")
                ?? bundle.url(forResource: "PlakotoValue", withExtension: "mlpackage") else {
            return XCTFail("PlakotoValue.mlpackage fixture missing")
        }
        let compiled = try await MLModel.compileModel(at: url)
        let model = try MLModel(contentsOf: compiled, configuration: MLModelConfiguration())
        let agent = Agent(model: model, encoder: BoardEncoder(config: config))

        let plies = Int(ProcessInfo.processInfo.environment["TAVLI_MEMORY_PLIES"] ?? "") ?? 12
        let record = Self.playOut(config: config, seed: 7, maxPlies: plies)

        // Warm up the model so its one-off load cost isn't counted as growth.
        _ = GameReview.analyze(record: GameRecord(startingPlayer: .white, aiColor: .black,
                                                  plies: Array(record.plies.prefix(2))),
                               agent: agent, humanColor: .white, depth: 1)

        let before = Self.footprintMB()
        let peak = PeakSampler()
        peak.start()
        let start = Date()
        let result = await Task.detached(priority: .userInitiated) {
            GameReview.analyzeProgressive(record: record, agent: agent, humanColor: .white,
                                          depths: [1, 2], includeOpponent: true)
        }.value
        let elapsed = Date().timeIntervalSince(start)
        let peakMB = peak.stop()
        let growth = peakMB - before
        print(String(format: "[analysis-memory] plies=%d evals=%d time=%.1fs before=%.0fMB peak=%.0fMB growth=%.0fMB",
                     record.plies.count, result.evaluations.count, elapsed, before, peakMB, growth))
        XCTAssertFalse(result.evaluations.isEmpty)
        XCTAssertLessThan(growth, 100, "analysis footprint grew \(Int(growth)) MB — per-inference memory is accumulating")
    }
}

/// Samples the footprint on a background thread so the peak during a long synchronous
/// job is seen, not just the value after it returns.
private final class PeakSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Double = 0
    private var running = true
    private var thread: Thread?

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    func start() {
        let t = Thread { [self] in
            while true {
                let v = Self.footprintMB()
                lock.lock()
                if v > peak { peak = v }
                let go = running
                lock.unlock()
                if !go { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        thread = t
        t.start()
    }

    func stop() -> Double {
        let v = Self.footprintMB()
        lock.lock()
        running = false
        if v > peak { peak = v }
        let p = peak
        lock.unlock()
        return p
    }
}
