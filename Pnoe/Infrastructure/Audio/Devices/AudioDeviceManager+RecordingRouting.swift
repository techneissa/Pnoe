import CoreAudio
import Foundation
import os

struct RecordingDeviceResolution {
    let deviceID: AudioDeviceID?
    let internalMicrophoneBlockedByClosedLid: Bool
    let fellBackFromClosedInternalMicrophone: Bool
}

struct RecordingDeviceSession {
    var isActive = false
    var activeDeviceID: AudioDeviceID?
    var isDeviceChangePending = false
}

enum RecordingDeviceChangeReason: Equatable {
    case closedLid
    case deviceUnavailable
}

struct RecordingDeviceChangeRequest {
    let fallbackDeviceID: AudioDeviceID?
    let reason: RecordingDeviceChangeReason
}

extension AudioDeviceManager {
    func setupRecordingDeviceRouting() {
        clamshellStateMonitor = ClamshellStateMonitor { [weak self] isClosed in
            self?.handleClamshellChange(isClosed: isClosed)
        }
    }

    func beginRecordingSetup(deviceID: AudioDeviceID) {
        recordingDeviceSession.isActive = true
        recordingDeviceSession.activeDeviceID = deviceID
    }

    func recordingDidStart(deviceID: AudioDeviceID) {
        recordingDeviceSession.isActive = true
        recordingDeviceSession.activeDeviceID = deviceID
    }

    func recordingDeviceChangeFinished(activeDeviceID: AudioDeviceID? = nil) {
        if let activeDeviceID {
            recordingDeviceSession.activeDeviceID = activeDeviceID
        }
        recordingDeviceSession.isDeviceChangePending = false
    }

    func recordingDidStop() {
        recordingDeviceSession = RecordingDeviceSession()
        // A device hidden during the recording leaves the selection now.
        if selectedDeviceIsExcluded {
            reconcileSelectionAfterVisibilityChange()
        }
    }

    func resolveCurrentRecordingDevice(
        excluding excludedDeviceID: AudioDeviceID? = nil
    ) -> RecordingDeviceResolution {
        let policy = recordingDevicePolicy()
        let preferredCandidates = policy.preferredDeviceIDs()
        let preferredAvailableDevice = preferredCandidates.first(where: isOperationalInputDevice)
        let internalMicrophoneBlockedByClosedLid = isClamshellClosed
            && preferredAvailableDevice.map(isInternalMicrophone) == true

        var seen = Set<AudioDeviceID>()
        let candidates = (preferredCandidates + policy.fallbackDeviceIDs()).filter { deviceID in
            guard deviceID != excludedDeviceID else { return false }
            return seen.insert(deviceID).inserted
        }
        let resolvedDeviceID = candidates.first(where: isDeviceUsableForRecording)

        return RecordingDeviceResolution(
            deviceID: resolvedDeviceID,
            internalMicrophoneBlockedByClosedLid: internalMicrophoneBlockedByClosedLid,
            fellBackFromClosedInternalMicrophone: internalMicrophoneBlockedByClosedLid
                && resolvedDeviceID != preferredAvailableDevice
        )
    }

    func getCurrentDevice() -> AudioDeviceID {
        resolveCurrentRecordingDevice().deviceID ?? 0
    }

    func findBestAvailableDevice() -> AudioDeviceID? {
        recordingDevicePolicy().fallbackDeviceIDs().first(where: isDeviceUsableForRecording)
    }

    func isDeviceUsableForRecording(_ deviceID: AudioDeviceID) -> Bool {
        isOperationalInputDevice(deviceID)
            && !(isClamshellClosed && isInternalMicrophone(deviceID))
    }

    func isOperationalInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        availableDevices.contains { $0.id == deviceID }
    }

    private func handleClamshellChange(isClosed: Bool) {
        logger.notice("Clamshell state changed: \(isClosed ? "closed" : "open", privacy: .public)")

        guard isRecordingActive else {
            notifyDeviceChange()
            return
        }
        guard isClosed,
            let activeRecordingDeviceID,
            isInternalMicrophone(activeRecordingDeviceID)
        else {
            return
        }

        requestRecordingDeviceChange(reason: .closedLid)
    }

    func requestRecordingDeviceChange(reason: RecordingDeviceChangeReason) {
        guard let activeDeviceID = activeRecordingDeviceID,
            !recordingDeviceSession.isDeviceChangePending
        else {
            return
        }

        recordingDeviceSession.isDeviceChangePending = true
        let request = RecordingDeviceChangeRequest(
            fallbackDeviceID: resolveCurrentRecordingDevice(excluding: activeDeviceID).deviceID,
            reason: reason
        )
        NotificationCenter.default.post(
            name: .recordingDeviceChangeRequired,
            object: request
        )
    }
}
