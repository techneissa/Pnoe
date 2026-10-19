import CoreAudio
import Foundation

/// One process with audio running, from the public CoreAudio process objects (macOS 14.2 and later).
struct AudioProcess: Sendable, Equatable {
    let pid: pid_t
    /// The process's bundle ID. Helper processes carry their own, for example `com.google.Chrome.helper`.
    let bundleID: String
    let isRunningOutput: Bool
    let isRunningInput: Bool
}

/// Lists the processes that have audio output or input running.
///
/// This says that some app is sending audio to an output device. It does not say that the app is the one the
/// system media keys control, and the output flag stays on for a few seconds after a player pauses.
/// `PlaybackController` accounts for both.
///
/// The CoreAudio queries run on a private serial queue, never on the main actor.
enum AudioOutputProcesses {
    private static let queue = DispatchQueue(label: "com.techneissa.pnoe.audio-processes", qos: .userInitiated)

    /// Processes with audio running, without Pnoe itself.
    static func snapshot() async -> [AudioProcess] {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: readProcesses())
            }
        }
    }

    private static func readProcesses() -> [AudioProcess] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var processes: [AudioProcess] = []

        for object in processObjects() {
            let isRunningOutput = flag(kAudioProcessPropertyIsRunningOutput, of: object)
            let isRunningInput = flag(kAudioProcessPropertyIsRunningInput, of: object)
            guard isRunningOutput || isRunningInput,
                let pid = pid(of: object), pid != ownPID
            else { continue }

            processes.append(
                AudioProcess(
                    pid: pid,
                    bundleID: bundleID(of: object) ?? "",
                    isRunningOutput: isRunningOutput,
                    isRunningInput: isRunningInput
                )
            )
        }
        return processes
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

    private static func flag(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) -> Bool {
        var address = propertyAddress(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }

    private static func pid(of object: AudioObjectID) -> pid_t? {
        var address = propertyAddress(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func bundleID(of object: AudioObjectID) -> String? {
        var address = propertyAddress(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value?.takeRetainedValue() as String?
    }

    private static func propertyAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
