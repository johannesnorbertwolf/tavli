import XCTest
@testable import TavliEngine

/// The `GameVariant` seam (#136): Plakoto is the default everywhere, the variant id
/// round-trips through persistence, and pre-variant files decode as Plakoto.
final class GameVariantTests: XCTestCase {

    func testStandardConfigIsPlakoto() {
        XCTAssertEqual(GameConfig.standard.variant.id, "plakoto")
        XCTAssertEqual(GameConfig.standard.variant.modelResourceName, "PlakotoValue")
        XCTAssertEqual(GameConfig(variantID: "plakoto"), .standard)
        XCTAssertEqual(GameConfig(variantID: "unknown-future-variant"), .standard)
        XCTAssertNotNil(GameVariants.variant(forID: "plakoto"))
        XCTAssertNil(GameVariants.variant(forID: "portes"))
    }

    func testPlakotoVariantMatchesUnderlyingPort() {
        let variant = PlakotoVariant()
        let board = GameBoard()
        variant.setUpInitialPosition(on: board)
        let reference = GameBoard()
        reference.initializeBoard()
        XCTAssertEqual(board.captureStacks(), reference.captureStacks())

        let dice = Dice()
        dice.set(3, 5)
        let viaVariant = variant.legalMoves(on: board, color: .white, dice: dice)
        let direct = PossibleMoves(board: board, color: .white, dice: dice).findMoves()
        XCTAssertEqual(viaVariant, direct)

        let before = board.captureStacks()
        variant.apply(viaVariant[0], on: board)
        XCTAssertNotEqual(board.captureStacks(), before)
        variant.undo(viaVariant[0], on: board)
        XCTAssertEqual(board.captureStacks(), before)

        XCTAssertFalse(variant.hasWon(.white, on: board))
        XCTAssertNil(variant.winner(on: board))
        XCTAssertEqual(variant.resultPoints(winner: .white, on: board), 1)
        XCTAssertEqual(variant.makeEncoder(config: .standard).inputSize,
                       BoardEncoder(config: .standard).inputSize)
    }

    @MainActor func testSessionRecordCarriesVariant() {
        let session = GameSession(animationTimings: .off)
        XCTAssertEqual(session.game.variant.id, "plakoto")
        XCTAssertEqual(session.record.variantID, "plakoto")
        XCTAssertEqual(session.snapshot(name: "s").variant, "plakoto")
    }

    func testSaveWithoutVariantDecodesAsPlakoto() throws {
        let legacy = """
        {"schemaVersion":1,"name":"old","savedAt":0,
         "startingPlayer":"W","history":[{"die1":3,"die2":5,"halfMoves":[[1,4]]}]}
        """
        let save = try JSONDecoder().decode(GameSave.self, from: Data(legacy.utf8))
        XCTAssertEqual(save.variant, "plakoto")
        XCTAssertEqual(save.record.variantID, "plakoto")

        let roundTripped = try JSONDecoder().decode(GameSave.self,
                                                    from: JSONEncoder().encode(save))
        XCTAssertEqual(roundTripped.variant, "plakoto")
    }

    func testOnlinePayloadWithoutVariantDecodesAsPlakoto() throws {
        let legacy = """
        {"schemaVersion":2,"targetWins":1,"startingPlayer":"W",
         "colorByPlayerID":{"a":"W","b":"B"},"games":[{"plies":[]}]}
        """
        let payload = try OnlineMatchPayload.decoded(from: Data(legacy.utf8))
        XCTAssertEqual(payload.variant, "plakoto")
        XCTAssertEqual(payload.gameSave().variant, "plakoto")
        let again = try OnlineMatchPayload.decoded(from: payload.encoded())
        XCTAssertEqual(again, payload)
    }
}
