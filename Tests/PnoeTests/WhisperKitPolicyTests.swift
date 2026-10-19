import XCTest

final class WhisperKitPolicyTests: XCTestCase {
    // MARK: Battery rule

    func testOnAlwaysUsesWhisperKit() {
        XCTAssertEqual(WhisperKitEnginePolicy.engine(usage: .on, power: .mains), .whisperKit)
        XCTAssertEqual(WhisperKitEnginePolicy.engine(usage: .on, power: .battery), .whisperKit)
    }

    func testOffNeverUsesWhisperKit() {
        XCTAssertEqual(WhisperKitEnginePolicy.engine(usage: .off, power: .mains), .fallback)
        XCTAssertEqual(WhisperKitEnginePolicy.engine(usage: .off, power: .battery), .fallback)
    }

    func testAutomaticUsesWhisperKitOnMainsAndFallbackOnBattery() {
        XCTAssertEqual(WhisperKitEnginePolicy.engine(usage: .automatic, power: .mains), .whisperKit)
        XCTAssertEqual(WhisperKitEnginePolicy.engine(usage: .automatic, power: .battery), .fallback)
    }

    func testEveryCombinationIsCovered() {
        let expected: [WhisperKitUsage: [PowerSource: WhisperKitEngineChoice]] = [
            .on: [.mains: .whisperKit, .battery: .whisperKit],
            .off: [.mains: .fallback, .battery: .fallback],
            .automatic: [.mains: .whisperKit, .battery: .fallback],
        ]
        for usage in WhisperKitUsage.allCases {
            for power in [PowerSource.mains, .battery] {
                XCTAssertEqual(
                    WhisperKitEnginePolicy.engine(usage: usage, power: power),
                    expected[usage]?[power],
                    "\(usage) on \(power)"
                )
            }
        }
    }

    // MARK: Fallback model

    func testFallbackPrefersTheUsersPickWhenUsable() {
        XCTAssertEqual(
            WhisperKitEnginePolicy.fallbackModelName(preferred: "ggml-base", usable: ["parakeet", "ggml-base"]),
            "ggml-base")
    }

    func testFallbackUsesTheFirstUsableWhenThePickIsMissingOrNotInstalled() {
        XCTAssertEqual(
            WhisperKitEnginePolicy.fallbackModelName(preferred: nil, usable: ["parakeet", "ggml-base"]), "parakeet")
        XCTAssertEqual(
            WhisperKitEnginePolicy.fallbackModelName(preferred: "deleted", usable: ["parakeet", "ggml-base"]),
            "parakeet")
    }

    func testNoFallbackWhenNothingElseIsInstalled() {
        XCTAssertNil(WhisperKitEnginePolicy.fallbackModelName(preferred: "ggml-base", usable: []))
    }

    // MARK: Stored setting

    private func makeDefaults() -> UserDefaults {
        let name = "WhisperKitPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testDefaultIsOn() {
        XCTAssertEqual(WhisperKitUsage.default, .on)
        XCTAssertEqual(WhisperKitUsage.stored(in: makeDefaults()), .on)
    }

    func testStoredValueRoundTripsAndUnknownValuesFallBackToDefault() {
        let defaults = makeDefaults()
        for usage in WhisperKitUsage.allCases {
            defaults.set(usage.rawValue, forKey: WhisperKitUsage.defaultsKey)
            XCTAssertEqual(WhisperKitUsage.stored(in: defaults), usage)
        }
        defaults.set("sometimes", forKey: WhisperKitUsage.defaultsKey)
        XCTAssertEqual(WhisperKitUsage.stored(in: defaults), .default)
    }

    func testUsagesAreOnOffAutomatic() {
        XCTAssertEqual(WhisperKitUsage.allCases.map(\.rawValue), ["on", "off", "automatic"])
    }

    // MARK: Power source

    func testPowerSourceReaderReturnsAState() {
        // The result depends on the machine; the call must work without a permission prompt.
        let power = PowerSourceReader.current()
        XCTAssertTrue(power == .mains || power == .battery)
    }
}
