import XCTest

final class AutoLearnBackupTests: XCTestCase {
    private let thresholdKey = "test.threshold"
    private let aiKey = "test.ai"

    private func makeDefaults() -> UserDefaults {
        let name = "AutoLearnBackupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testRoundTripThroughJSON() throws {
        let source = makeDefaults()
        source.set(4, forKey: thresholdKey)
        source.set(true, forKey: aiKey)
        let exported = AutoLearnBackupSettings.current(in: source, thresholdKey: thresholdKey, usesAIReviewKey: aiKey)
        let decoded = try JSONDecoder().decode(
            AutoLearnBackupSettings.self, from: JSONEncoder().encode(exported))

        let target = makeDefaults()
        decoded.apply(to: target, thresholdKey: thresholdKey, usesAIReviewKey: aiKey)

        XCTAssertEqual(target.integer(forKey: thresholdKey), 4)
        XCTAssertTrue(target.bool(forKey: aiKey))
    }

    func testOldBackupWithoutKeysLeavesCurrentValues() throws {
        let decoded = try JSONDecoder().decode(AutoLearnBackupSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, AutoLearnBackupSettings())

        let defaults = makeDefaults()
        defaults.set(5, forKey: thresholdKey)
        defaults.set(true, forKey: aiKey)
        decoded.apply(to: defaults, thresholdKey: thresholdKey, usesAIReviewKey: aiKey)

        XCTAssertEqual(defaults.integer(forKey: thresholdKey), 5)
        XCTAssertTrue(defaults.bool(forKey: aiKey))

        let fresh = makeDefaults()
        decoded.apply(to: fresh, thresholdKey: thresholdKey, usesAIReviewKey: aiKey)
        XCTAssertNil(fresh.object(forKey: thresholdKey))
        XCTAssertNil(fresh.object(forKey: aiKey))
    }

    func testUnsupportedThresholdIsIgnored() {
        let defaults = makeDefaults()
        defaults.set(3, forKey: thresholdKey)
        AutoLearnBackupSettings(repeatThreshold: 99).apply(
            to: defaults, thresholdKey: thresholdKey, usesAIReviewKey: aiKey)
        XCTAssertEqual(defaults.integer(forKey: thresholdKey), 3)
    }

    func testExportUsesDefaultThresholdWhenUnset() {
        let exported = AutoLearnBackupSettings.current(
            in: makeDefaults(), thresholdKey: thresholdKey, usesAIReviewKey: aiKey)
        XCTAssertEqual(exported.repeatThreshold, AutoLearnRepeatThreshold.default.rawValue)
        XCTAssertEqual(exported.usesAIReview, false)
    }
}
