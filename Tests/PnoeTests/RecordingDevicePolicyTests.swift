import CoreAudio
import XCTest

/// Headless checks for hiding input devices: injected device lists, no Core Audio and no audio.
final class RecordingDevicePolicyTests: XCTestCase {
    private let builtIn = InputDeviceInfo(
        id: 1, uid: "built-in-uid", name: "Built-in Microphone", modelUID: nil, isInternalMicrophone: true)
    private let headset = InputDeviceInfo(
        id: 2, uid: "headset-uid", name: "Wireless Headset", modelUID: "headset-model", isInternalMicrophone: false)
    private let usbMic = InputDeviceInfo(
        id: 3, uid: "usb-uid", name: "USB Microphone", modelUID: "usb-model", isInternalMicrophone: false)
    private let virtual = InputDeviceInfo(
        id: 4, uid: "virtual-uid", name: "Virtual Device", modelUID: nil, isInternalMicrophone: false)

    private func policy(
        _ mode: AudioInputMode,
        devices: [InputDeviceInfo]? = nil,
        hidden: Set<String> = [],
        systemDefault: AudioDeviceID? = nil,
        customUID: String = "",
        selected: AudioDeviceID? = nil,
        prioritized: [String] = [],
        lidClosed: Bool = false
    ) -> RecordingDevicePolicy {
        RecordingDevicePolicy(
            mode: mode,
            devices: devices ?? [builtIn, headset, usbMic, virtual],
            hiddenUIDs: hidden,
            systemDefaultID: systemDefault,
            customUID: customUID,
            selectedDeviceID: selected,
            prioritized: prioritized.enumerated().map {
                PrioritizedDevice(id: $0.element, name: $0.element, priority: $0.offset, modelUID: nil)
            },
            isClamshellClosed: lidClosed)
    }

    private func firstChoice(_ policy: RecordingDevicePolicy) -> AudioDeviceID? {
        (policy.preferredDeviceIDs() + policy.fallbackDeviceIDs()).first
    }

    func testHiddenSystemDefaultIsSkippedAndFallsBackToBuiltIn() {
        let visible = policy(.systemDefault, systemDefault: 2)
        XCTAssertEqual(firstChoice(visible), 2)

        let hidden = policy(.systemDefault, hidden: ["headset-uid"], systemDefault: 2)
        XCTAssertEqual(hidden.preferredDeviceIDs(), [])
        XCTAssertEqual(firstChoice(hidden), 1)
        XCTAssertFalse(hidden.fallbackDeviceIDs().contains(2))
    }

    func testHiddenPriorityEntryIsSkippedForTheNextOne() {
        let order = ["headset-uid", "usb-uid", "built-in-uid"]
        XCTAssertEqual(policy(.prioritized, prioritized: order).preferredDeviceIDs(), [2, 3, 1])

        let hidden = policy(.prioritized, hidden: ["headset-uid"], prioritized: order)
        XCTAssertEqual(hidden.preferredDeviceIDs(), [3, 1])
        XCTAssertEqual(firstChoice(hidden), 3)
    }

    func testHiddenPriorityEntryIsSkippedEvenWhenMatchedByModel() {
        let sameModel = InputDeviceInfo(
            id: 5, uid: "headset-uid-2", name: "Wireless Headset", modelUID: "headset-model",
            isInternalMicrophone: false)
        let devices = [builtIn, headset, sameModel]
        var p = policy(.prioritized, devices: devices, hidden: ["headset-uid"])
        p.prioritized = [PrioritizedDevice(id: "gone-uid", name: "Headset", priority: 0, modelUID: "headset-model")]
        XCTAssertEqual(p.preferredDeviceIDs(), [5], "model match lands on the allowed device, never the hidden one")
    }

    func testHiddenCustomDeviceFallsBackWhileTheSavedChoiceStays() {
        let hidden = policy(.custom, hidden: ["usb-uid"], customUID: "usb-uid", selected: 3)
        XCTAssertEqual(hidden.preferredDeviceIDs(), [])
        XCTAssertEqual(firstChoice(hidden), 1)

        let shown = policy(.custom, customUID: "usb-uid", selected: 3)
        XCTAssertEqual(firstChoice(shown), 3)
    }

    func testFallbackOrderFollowsTheLid() {
        XCTAssertEqual(policy(.systemDefault, hidden: ["virtual-uid"]).fallbackDeviceIDs(), [1, 2, 3])
        XCTAssertEqual(policy(.systemDefault, hidden: ["virtual-uid"], lidClosed: true).fallbackDeviceIDs(), [2, 3, 1])
    }

    func testAllHiddenFallsBackToTheBuiltInMicrophone() {
        let all: Set<String> = ["built-in-uid", "headset-uid", "usb-uid", "virtual-uid"]
        for mode in AudioInputMode.allCases {
            let p = policy(mode, hidden: all, systemDefault: 2, customUID: "usb-uid", selected: 3,
                prioritized: ["headset-uid", "usb-uid"])
            XCTAssertTrue(p.allDevicesHidden)
            XCTAssertEqual(p.preferredDeviceIDs(), [], "\(mode)")
            XCTAssertEqual(firstChoice(p), 1, "\(mode)")
        }
    }

    func testAllHiddenWithoutBuiltInUsesAConnectedDeviceInsteadOfNone() {
        let p = policy(.systemDefault, devices: [headset, usbMic], hidden: ["headset-uid", "usb-uid"], systemDefault: 2)
        XCTAssertTrue(p.allDevicesHidden)
        XCTAssertEqual(p.fallbackDeviceIDs(), [2, 3])
    }

    func testNoDevicesIsNotAllHidden() {
        let p = policy(.systemDefault, devices: [], hidden: ["headset-uid"])
        XCTAssertFalse(p.allDevicesHidden)
        XCTAssertEqual(p.fallbackDeviceIDs(), [])
    }

    func testHiddenBuiltInStillLetsOtherDevicesRecord() {
        let p = policy(.systemDefault, hidden: ["built-in-uid"], systemDefault: 1)
        XCTAssertFalse(p.allDevicesHidden)
        XCTAssertEqual(firstChoice(p), 2)
    }

    func testReconnectWithTheSameUIDStaysHidden() {
        // The same hardware comes back with a new Core Audio ID; hiding is keyed by UID.
        let reconnected = InputDeviceInfo(
            id: 42, uid: "headset-uid", name: "Wireless Headset", modelUID: "headset-model",
            isInternalMicrophone: false)
        let p = policy(.systemDefault, devices: [builtIn, reconnected], hidden: ["headset-uid"], systemDefault: 42)
        XCTAssertTrue(p.isHidden(deviceID: 42))
        XCTAssertEqual(firstChoice(p), 1)
    }

    func testHiddenDevicesSurviveARestart() throws {
        let suite = "PnoeHiddenDevices-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(defaults.hiddenAudioDeviceNamesByUID, [:])
        defaults.hiddenAudioDeviceNamesByUID = ["headset-uid": "Wireless Headset"]

        let restarted = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(restarted.hiddenAudioDeviceNamesByUID, ["headset-uid": "Wireless Headset"])
    }

    func testSettingsRowsListConnectedAndAbsentHiddenDevices() {
        let rows = RecordingDevicePolicy.visibilityRows(
            connected: [usbMic, builtIn],
            hiddenNamesByUID: ["usb-uid": "USB Microphone", "old-uid": "Old Interface", "airpods-uid": "Wireless Earbuds"])
        XCTAssertEqual(rows.map(\.name), ["Built-in Microphone", "USB Microphone", "Old Interface", "Wireless Earbuds"])
        XCTAssertEqual(rows.map(\.isConnected), [true, true, false, false])
        XCTAssertEqual(rows.map(\.isHidden), [false, true, true, true])
    }

    func testHiddenSavedDeviceIsNotSwappedForASameModelDeviceAndUnhidingRestoresIt() {
        let saved = InputDeviceInfo(
            id: 10, uid: "pair-a", name: "Studio Microphone", modelUID: "studio-model", isInternalMicrophone: false)
        let twin = InputDeviceInfo(
            id: 11, uid: "pair-b", name: "Studio Microphone", modelUID: "studio-model", isInternalMicrophone: false)
        func policy(hidden: Set<String>, selected: AudioDeviceID?) -> RecordingDevicePolicy {
            var p = self.policy(.custom, devices: [builtIn, saved, twin], hidden: hidden, customUID: "pair-a", selected: selected)
            p.customModelUID = "studio-model"
            return p
        }

        XCTAssertNil(policy(hidden: ["pair-a"], selected: nil).findAllowedDevice(uid: "pair-a", modelUID: "studio-model"),
            "the saved device is connected but hidden: its twin must not stand in for it")
        XCTAssertEqual(policy(hidden: ["pair-a"], selected: nil).preferredDeviceIDs(), [])
        XCTAssertEqual(firstChoice(policy(hidden: ["pair-a"], selected: nil)), 1)

        // The selection sits on a fallback while hidden; unhiding goes back to the saved device.
        XCTAssertEqual(firstChoice(policy(hidden: [], selected: 1)), 10)
        XCTAssertEqual(firstChoice(policy(hidden: [], selected: 11)), 10)
    }

    func testModelUIDStillStandsInForASavedDeviceThatIsNotConnected() {
        let twin = InputDeviceInfo(
            id: 11, uid: "pair-b", name: "Studio Microphone", modelUID: "studio-model", isInternalMicrophone: false)
        XCTAssertEqual(
            RecordingDevicePolicy.find(uid: "pair-a", modelUID: "studio-model", in: [builtIn, twin], hiddenUIDs: []), twin)
        XCTAssertNil(
            RecordingDevicePolicy.find(uid: "pair-a", modelUID: "studio-model", in: [builtIn, twin], hiddenUIDs: ["pair-b"]))
    }

    func testAllHiddenNoticeNamesWhatRecordingUses() {
        let all: Set<String> = ["built-in-uid", "headset-uid"]
        XCTAssertEqual(
            policy(.systemDefault, devices: [builtIn, headset], hidden: all).allHiddenFallback, .builtInMicrophone)
        XCTAssertEqual(
            policy(.systemDefault, devices: [builtIn, headset], hidden: all, lidClosed: true).allHiddenFallback,
            .input(name: "Wireless Headset"))
        XCTAssertEqual(
            policy(.systemDefault, devices: [headset], hidden: ["headset-uid"]).allHiddenFallback,
            .input(name: "Wireless Headset"))
        XCTAssertEqual(
            policy(.systemDefault, devices: [builtIn], hidden: ["built-in-uid"], lidClosed: true).allHiddenFallback,
            .unavailable)
        XCTAssertNil(policy(.systemDefault, hidden: ["headset-uid"]).allHiddenFallback)
    }

    func testMalformedStoredHiddenDevicesReadAsEmpty() throws {
        let suite = "PnoeHiddenDevicesMalformed-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("not a dictionary", forKey: "hiddenAudioDeviceNamesByUID")
        XCTAssertEqual(defaults.hiddenAudioDeviceNamesByUID, [:])
        defaults.set(["headset-uid", "usb-uid"], forKey: "hiddenAudioDeviceNamesByUID")
        XCTAssertEqual(defaults.hiddenAudioDeviceNamesByUID, [:])
        defaults.set(["headset-uid": 7], forKey: "hiddenAudioDeviceNamesByUID")
        XCTAssertEqual(defaults.hiddenAudioDeviceNamesByUID, [:])
    }
}
