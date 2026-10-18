import AppKit
import XCTest

/// Headless checks for `TextFieldPolicy`: no app launch, no window on screen. The windows below
/// are built in memory and never ordered front.
@MainActor
final class TextFieldPolicyTests: XCTestCase {
    private let launchDefaultKeys = [
        "NSAutoFillHeuristicsEnabled",
        "NSAutomaticTextCompletionEnabled",
        "NSAutomaticInlinePredictionEnabled",
        "NSAutomaticSpellingCorrectionEnabled",
        "NSAutomaticQuoteSubstitutionEnabled",
        "NSAutomaticDashSubstitutionEnabled",
        "NSAutomaticTextReplacementEnabled",
        "NSAutomaticPeriodSubstitutionEnabled",
        "NSAutomaticCapitalizationEnabled",
    ]

    override func tearDown() {
        for key in launchDefaultKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    func testLaunchDefaultsDisableEveryFeature() {
        // The user's System Settings values win unless the app domain sets them explicitly.
        for key in launchDefaultKeys {
            UserDefaults.standard.set(true, forKey: key)
        }

        TextFieldPolicy.installLaunchDefaults()

        for key in launchDefaultKeys {
            XCTAssertNotNil(UserDefaults.standard.object(forKey: key), key)
            XCTAssertFalse(UserDefaults.standard.bool(forKey: key), key)
        }
    }

    func testApplyDisablesEveryTextViewFeature() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textView.isAutomaticTextCompletionEnabled = true
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = true
        textView.isAutomaticTextReplacementEnabled = true
        textView.inlinePredictionType = .yes
        textView.writingToolsBehavior = .complete

        TextFieldPolicy.apply(to: textView)

        XCTAssertFalse(textView.isAutomaticTextCompletionEnabled)
        XCTAssertFalse(textView.isAutomaticSpellingCorrectionEnabled)
        XCTAssertFalse(textView.isContinuousSpellCheckingEnabled)
        XCTAssertFalse(textView.isGrammarCheckingEnabled)
        XCTAssertFalse(textView.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(textView.isAutomaticDashSubstitutionEnabled)
        XCTAssertFalse(textView.isAutomaticTextReplacementEnabled)
        XCTAssertEqual(textView.inlinePredictionType, .no)
        XCTAssertEqual(textView.writingToolsBehavior, .none)
    }

    // MARK: Click-away

    private struct Fixture {
        let window: NSWindow
        let field: NSTextField
        let container: NSView
    }

    /// A 400x300 window with a text field at the top left and empty space elsewhere.
    private func makeFixture() -> Fixture {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: true)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let field = NSTextField(frame: NSRect(x: 20, y: 240, width: 160, height: 24))
        container.addSubview(field)
        window.contentView = container
        return Fixture(window: window, field: field, container: container)
    }

    func testClickAwayDoesNothingWithoutFieldEditor() {
        let fixture = makeFixture()
        XCTAssertFalse(TextFieldPolicy.clickEndsEditing(at: NSPoint(x: 300, y: 50), in: fixture.window))
    }

    func testClickOnEmptySpaceEndsEditing() {
        let fixture = makeFixture()
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.field))
        let editor = fixture.window.firstResponder as? NSTextView
        XCTAssertEqual(editor?.isFieldEditor, true)

        XCTAssertTrue(TextFieldPolicy.clickEndsEditing(at: NSPoint(x: 300, y: 50), in: fixture.window))
    }

    func testClickInsideTheFocusedFieldKeepsEditing() {
        let fixture = makeFixture()
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.field))

        let inside = fixture.container.convert(NSPoint(x: 100, y: 252), to: nil)
        XCTAssertFalse(TextFieldPolicy.clickEndsEditing(at: inside, in: fixture.window))
    }

    func testClickOnAnotherTextFieldKeepsEditing() {
        let fixture = makeFixture()
        let other = NSTextField(frame: NSRect(x: 20, y: 200, width: 160, height: 24))
        fixture.container.addSubview(other)
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.field))

        let onOther = fixture.container.convert(NSPoint(x: 100, y: 212), to: nil)
        XCTAssertFalse(TextFieldPolicy.clickEndsEditing(at: onOther, in: fixture.window))
    }
}
