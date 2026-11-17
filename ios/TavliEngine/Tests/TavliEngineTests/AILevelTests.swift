import XCTest
@testable import TavliEngine

/// #189 — level 1…8 → search config, and the one-time settings migrations.
final class AILevelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AILevelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testLevel8IsFullStrengthTwoPlyNoNoise() {
        let c = AILevel.searchConfig(for: 8)
        XCTAssertEqual(c.maxDepth, 2)
        XCTAssertEqual(c.selectionNoise, 0)
    }

    func testLevel7IsOnePlyNoNoise() {
        let c = AILevel.searchConfig(for: 7)
        XCTAssertEqual(c.maxDepth, 1)
        XCTAssertEqual(c.selectionNoise, 0)
    }

    func testLevels6To1AreOnePlyWithStrictlyIncreasingNoise() {
        var previous: Float = 0
        for level in stride(from: 6, through: 1, by: -1) {
            let c = AILevel.searchConfig(for: level)
            XCTAssertEqual(c.maxDepth, 1, "level \(level)")
            XCTAssertGreaterThan(c.selectionNoise, previous, "level \(level)")
            previous = c.selectionNoise
        }
        // Level 1 keeps the old slider's weakest setting.
        XCTAssertEqual(AILevel.selectionNoise(for: 1), AILevel.legacySigmaMax)
    }

    func testOnlyDifficultyKnobsChange() {
        let base = SearchConfig.standard
        for level in AILevel.range {
            var c = AILevel.searchConfig(for: level)
            c.maxDepth = base.maxDepth
            c.selectionNoise = base.selectionNoise
            XCTAssertEqual(c, base, "level \(level)")
        }
    }

    func testOutOfRangeLevelsClamp() {
        XCTAssertEqual(AILevel.searchConfig(for: 0), AILevel.searchConfig(for: 1))
        XCTAssertEqual(AILevel.searchConfig(for: 99), AILevel.searchConfig(for: 8))
    }

    func testNearestLevelToLegacyStrength() {
        XCTAssertEqual(AILevel.nearest(toLegacyStrength: 1.0), 8)
        XCTAssertEqual(AILevel.nearest(toLegacyStrength: 0.999), 7)   // σ 0.0001
        XCTAssertEqual(AILevel.nearest(toLegacyStrength: 0.9), 6)     // σ 0.010
        XCTAssertEqual(AILevel.nearest(toLegacyStrength: 0.75), 5)    // σ 0.025
        XCTAssertEqual(AILevel.nearest(toLegacyStrength: 0.6), 4)     // σ 0.040
        XCTAssertEqual(AILevel.nearest(toLegacyStrength: 0.5), 3)     // σ 0.050
        XCTAssertEqual(AILevel.nearest(toLegacyStrength: 0.3), 2)     // σ 0.070
        XCTAssertEqual(AILevel.nearest(toLegacyStrength: 0.0), 1)     // σ 0.100
        XCTAssertEqual(AILevel.nearest(toLegacyStrength: -1), 1)
    }

    func testLoadDefaultsToFullStrength() {
        XCTAssertEqual(AILevel.load(from: defaults), 8)
        defaults.set(3, forKey: AILevel.storageKey)
        XCTAssertEqual(AILevel.load(from: defaults), 3)
        defaults.set(42, forKey: AILevel.storageKey)
        XCTAssertEqual(AILevel.load(from: defaults), 8)
    }

    func testMigrateStoresNearestLevelAndDropsSlider() {
        defaults.set(0.5, forKey: AILevel.legacyStrengthKey)
        AILevel.migrate(defaults)
        XCTAssertEqual(defaults.object(forKey: AILevel.storageKey) as? Int, 3)
        XCTAssertNil(defaults.object(forKey: AILevel.legacyStrengthKey))
        AILevel.migrate(defaults)   // idempotent
        XCTAssertEqual(AILevel.load(from: defaults), 3)
    }

    func testMigrateKeepsAnExistingLevel() {
        defaults.set(5, forKey: AILevel.storageKey)
        defaults.set(0.0, forKey: AILevel.legacyStrengthKey)
        AILevel.migrate(defaults)
        XCTAssertEqual(AILevel.load(from: defaults), 5)
        XCTAssertNil(defaults.object(forKey: AILevel.legacyStrengthKey))
    }

    func testMigrateWithoutSliderLeavesDefault() {
        AILevel.migrate(defaults)
        XCTAssertNil(defaults.object(forKey: AILevel.storageKey))
        XCTAssertEqual(AILevel.load(from: defaults), 8)
    }

    func testPlayAsAskMigratesToRandom() {
        defaults.set("ask", forKey: PlayAsPreference.storageKey)
        PlayAsPreference.migrate(defaults)
        XCTAssertEqual(defaults.string(forKey: PlayAsPreference.storageKey), "random")
    }

    func testPlayAsOtherValuesUntouched() {
        defaults.set("black", forKey: PlayAsPreference.storageKey)
        PlayAsPreference.migrate(defaults)
        XCTAssertEqual(defaults.string(forKey: PlayAsPreference.storageKey), "black")
        defaults.removeObject(forKey: PlayAsPreference.storageKey)
        PlayAsPreference.migrate(defaults)
        XCTAssertNil(defaults.string(forKey: PlayAsPreference.storageKey))
    }
}
