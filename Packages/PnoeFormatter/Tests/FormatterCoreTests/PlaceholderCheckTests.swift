import Testing
@testable import FormatterCore

@Suite("PlaceholderCheck")
struct PlaceholderCheckTests {
    static let protected = TokenProtector.protect("open config dot yaml and read utils slash text dot py then tell me")
    // text: "open ⟦1⟧ and read ⟦2⟧ then tell me"

    @Test func baselineText() {
        #expect(Self.protected.text == "open ⟦1⟧ and read ⟦2⟧ then tell me")
    }

    @Test(arguments: [
        "Open ⟦1⟧ and read ⟦2⟧, then tell me.",
        "Then tell me: open ⟦1⟧ and read ⟦2⟧." as String,
    ])
    func passesWhenEachMarkerAppearsOnceInOrder(_ output: String) {
        // The second text reorders words but not markers.
        #expect(PlaceholderCheck.validate(output, protected: Self.protected) == nil)
    }

    @Test(arguments: [
        ("Open ⟦1⟧ and read the file.", FallbackReason.placeholderLost),
        ("Open config.yaml and read ⟦2⟧.", .placeholderLost),
        ("Open and read.", .placeholderLost),
        ("Open ⟦1⟧ and read ⟦2⟧ and ⟦1⟧.", .placeholderDup),
        ("Open ⟦1⟧⟦1⟧ and read ⟦2⟧.", .placeholderDup),
        ("Read ⟦2⟧ and open ⟦1⟧.", .placeholderOrder),
        ("Open ⟦1⟧ and read ⟦2⟧ and ⟦3⟧.", .placeholderUnknown),
        ("Open ⟦1⟧ and read ⟦2⟧⟧.", .placeholderUnknown),
        ("Open ⟦1 and read ⟦2⟧.", .placeholderUnknown),
        ("Open [1] and read ⟦2⟧.", .placeholderLost),
        ("Open ⟦one⟧ and read ⟦2⟧.", .placeholderUnknown),
    ])
    func rejects(_ output: String, _ reason: FallbackReason) {
        #expect(PlaceholderCheck.validate(output, protected: Self.protected) == reason)
    }

    @Test func aMarkerInsideACorrectedStretchMayBeDropped() {
        let p = TokenProtector.protect("open config dot yaml and change the port to 8080 no wait 9090")
        #expect(p.text == "open ⟦1⟧ and change the port to ⟦2⟧ no wait ⟦3⟧")
        #expect(PlaceholderCheck.validate("Open ⟦1⟧ and change the port to ⟦3⟧.", protected: p) == nil)
        // Keeping the corrected one too is fine for this check (the model may keep it; the diff guard judges).
        #expect(PlaceholderCheck.validate("Open ⟦1⟧ and change the port to ⟦2⟧, no wait, ⟦3⟧.", protected: p) == nil)
        // The marker outside the correction window must stay.
        #expect(PlaceholderCheck.validate("Change the port to ⟦3⟧.", protected: p) == .placeholderLost)
    }

    @Test func aMarkerFarBeforeTheCorrectionMustStay() {
        let p = TokenProtector.protect("open config dot yaml and then change the port to 8080 no wait 9090 please")
        #expect(PlaceholderCheck.validate("Then change the port to ⟦3⟧ please.", protected: p) == .placeholderLost)
    }
}
