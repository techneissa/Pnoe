import CoreAudio
import Foundation

/// Lists the processes that currently have an audio output running, using the public
/// CoreAudio process objects (macOS 14.2 and later).
///
/// This says that some app is sending audio to an output device. It does not say that the app
/// is the one the system media keys control, and the flag stays on for a few seconds after a
/// player pauses. `PlaybackController` accounts for both.
enum AudioOutputProcesses {
    /// Process IDs with audio output running, without Pnoe itself.
    static func currentProcessIDs() -> Set<pid_t> {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var processIDs = Set<pid_t>()

        for processObject in processObjects() where isRunningOutput(processObject) {
            guard let pid = pid(of: processObject), pid != ownPID else { continue }
            processIDs.insert(pid)
        }
        return processIDs
    }

    private static func processObjects() -> [AudioObjectID] {
        var address = propertyAddress(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
            size > 0
        else {
            return []
        }

        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects)
                == noErr
        else {
            return []
        }
        return objects
    }

    private static func isRunningOutput(_ processObject: AudioObjectID) -> Bool {
        var address = propertyAddress(kAudioProcessPropertyIsRunningOutput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(processObject, &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }

    private static func pid(of processObject: AudioObjectID) -> pid_t? {
        var address = propertyAddress(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(processObject, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func propertyAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
