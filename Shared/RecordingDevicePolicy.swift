import CoreAudio
import Foundation

struct PrioritizedDevice: Codable, Identifiable {
    let id: String
    let name: String
    let priority: Int
    var modelUID: String?
}

enum AudioInputMode: String, CaseIterable {
    case systemDefault = "System Default"
    case custom = "Custom Device"
    case prioritized = "Prioritized"
}

extension UserDefaults {
    /// Hidden input devices: device UID to the last known name.
    var hiddenAudioDeviceNamesByUID: [String: String] {
        get { dictionary(forKey: "hiddenAudioDeviceNamesByUID") as? [String: String] ?? [:] }
        set { set(newValue, forKey: "hiddenAudioDeviceNamesByUID") }
    }
}

/// One connected input device, as the selection policy sees it.
struct InputDeviceInfo: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let modelUID: String?
    let isInternalMicrophone: Bool
}

/// The device recording falls back to when every input is hidden.
enum AllHiddenFallback: Equatable {
    case builtInMicrophone
    /// A Mac without a built-in microphone, or with the lid closed.
    case input(name: String)
    /// Only the built-in microphone is connected and the lid is closed.
    case unavailable
}

/// One row of the audio settings device list.
struct MicrophoneVisibilityRow: Equatable, Identifiable {
    let uid: String
    let name: String
    let isConnected: Bool
    let isHidden: Bool
    var id: String { uid }
}

/// Decides which devices a recording may use. Pure: the manager hands it the connected devices and
/// the settings, so the rules are testable without Core Audio.
///
/// A hidden device is never a candidate: not through the system default, a custom choice or the
/// priority list. Candidates run preferred first, then every other allowed device (built-in
/// microphone first, last when the lid is closed). When every connected device is hidden there is
/// nothing allowed to fall back to, so the policy ignores the hidden flags for the fallback only:
/// the built-in microphone comes first rather than recording failing silently.
struct RecordingDevicePolicy {
    var mode: AudioInputMode
    var devices: [InputDeviceInfo]
    var hiddenUIDs: Set<String>
    var systemDefaultID: AudioDeviceID?
    var customUID: String = ""
    var customModelUID: String?
    var selectedDeviceID: AudioDeviceID?
    var prioritized: [PrioritizedDevice] = []
    var isClamshellClosed = false

    var allowedDevices: [InputDeviceInfo] {
        devices.filter { !hiddenUIDs.contains($0.uid) }
    }

    /// True when devices are connected but none of them may be used.
    var allDevicesHidden: Bool {
        !devices.isEmpty && allowedDevices.isEmpty
    }

    func isHidden(deviceID: AudioDeviceID) -> Bool {
        devices.first { $0.id == deviceID }.map { hiddenUIDs.contains($0.uid) } ?? false
    }

    /// Matches by UID, then by model UID, among the allowed devices.
    func findAllowedDevice(uid: String, modelUID: String?) -> InputDeviceInfo? {
        Self.find(uid: uid, modelUID: modelUID, in: devices, hiddenUIDs: hiddenUIDs)
    }

    /// The model UID only stands in for a saved device that is not connected. A saved device that
    /// is connected but hidden finds nothing, so a visible device of the same model never takes
    /// its place and the saved choice comes back once it is shown again.
    static func find(
        uid: String, modelUID: String?, in devices: [InputDeviceInfo], hiddenUIDs: Set<String>
    ) -> InputDeviceInfo? {
        if !uid.isEmpty, let connected = devices.first(where: { $0.uid == uid }) {
            return hiddenUIDs.contains(connected.uid) ? nil : connected
        }
        if let modelUID, !modelUID.isEmpty,
            let found = devices.first(where: { $0.modelUID == modelUID && !hiddenUIDs.contains($0.uid) })
        {
            return found
        }
        return nil
    }

    func preferredDeviceIDs() -> [AudioDeviceID] {
        switch mode {
        case .systemDefault:
            guard let systemDefaultID, allowedDevices.contains(where: { $0.id == systemDefaultID }) else {
                return []
            }
            return [systemDefaultID]
        case .custom:
            var candidates = findAllowedDevice(uid: customUID, modelUID: customModelUID).map { [$0.id] } ?? []
            if let selectedDeviceID, !candidates.contains(selectedDeviceID),
                allowedDevices.contains(where: { $0.id == selectedDeviceID })
            {
                candidates.append(selectedDeviceID)
            }
            return candidates
        case .prioritized:
            return prioritized.sorted { $0.priority < $1.priority }.compactMap { device in
                findAllowedDevice(uid: device.id, modelUID: device.modelUID)?.id
            }
        }
    }

    func fallbackDeviceIDs() -> [AudioDeviceID] {
        let pool = allDevicesHidden ? devices : allowedDevices
        let internalMicrophones = pool.filter(\.isInternalMicrophone).map(\.id)
        let otherInputs = pool.filter { !$0.isInternalMicrophone }.map(\.id)
        return isClamshellClosed ? otherInputs + internalMicrophones : internalMicrophones + otherInputs
    }

    /// What recording uses when every connected device is hidden, for the settings notice.
    /// Nil when some device is allowed.
    var allHiddenFallback: AllHiddenFallback? {
        guard allDevicesHidden else { return nil }
        let usable = fallbackDeviceIDs().compactMap { id in devices.first { $0.id == id } }
            .first { !(isClamshellClosed && $0.isInternalMicrophone) }
        guard let usable else { return .unavailable }
        return usable.isInternalMicrophone ? .builtInMicrophone : .input(name: usable.name)
    }

    /// Settings list: every connected device, then the hidden ones that are not connected now,
    /// each group by name.
    static func visibilityRows(
        connected: [InputDeviceInfo], hiddenNamesByUID: [String: String]
    ) -> [MicrophoneVisibilityRow] {
        func byName(_ lhs: MicrophoneVisibilityRow, _ rhs: MicrophoneVisibilityRow) -> Bool {
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        let connectedRows = connected.map {
            MicrophoneVisibilityRow(
                uid: $0.uid, name: $0.name, isConnected: true, isHidden: hiddenNamesByUID[$0.uid] != nil)
        }
        let connectedUIDs = Set(connected.map(\.uid))
        let absentRows = hiddenNamesByUID.filter { !connectedUIDs.contains($0.key) }.map {
            MicrophoneVisibilityRow(uid: $0.key, name: $0.value, isConnected: false, isHidden: true)
        }
        return connectedRows.sorted(by: byName) + absentRows.sorted(by: byName)
    }
}
