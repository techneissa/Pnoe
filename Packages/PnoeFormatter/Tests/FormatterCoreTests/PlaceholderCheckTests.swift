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

    @Test func aPlainApologyOpensNoDropWindow() {
        // "sorry" and "I mean" are ordinary speech, not corrections.
        for phrase in ["sorry", "i mean", "sorry about that"] {
            let p = TokenProtector.protect("send the note to tom at example dot com \(phrase) about the delay")
            #expect(PlaceholderCheck.validate("Send the note about the delay.", protected: p) == .placeholderLost, "\(phrase)")
        }
    }

    @Test func aCorrectionPhraseNeedsAReplacementOfTheSameKind() {
        // "no wait" with nothing after it that replaces the address: the address must stay.
        let none = TokenProtector.protect("send it to tom at example dot com no wait about the delay please")
        #expect(PlaceholderCheck.validate("Send it about the delay please.", protected: none) == .placeholderLost)
        // A replacement of another kind (a number for an address) does not excuse it either.
        let wrongKind = TokenProtector.protect("send it to tom at example dot com no wait 9090 please")
        #expect(PlaceholderCheck.validate("Send it to ⟦2⟧ please.", protected: wrongKind) == .placeholderLost)
        // Same kind after the phrase: fine.
        let same = TokenProtector.protect("send it to tom at example dot com no wait jo at example dot com please")
        #expect(PlaceholderCheck.validate("Send it to ⟦2⟧ please.", protected: same) == nil)
    }
}
