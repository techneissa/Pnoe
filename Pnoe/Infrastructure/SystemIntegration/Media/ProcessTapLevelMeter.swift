import AudioToolbox
import CoreAudio
import Foundation
import os

/// Reads the level of some processes' audio through a CoreAudio process tap (macOS 14.2 and later).
///
/// A tap listens without changing what the user hears (`muteBehavior` is `.unmuted`). The first tap makes macOS ask
/// for the System Audio Recording permission, which is why `PlaybackController` uses this only when the user turned
/// the level check on. The tap lives for one measuring window and is private to Pnoe: no other app sees it.
///
/// The tap, the private aggregate device that carries it and the IO callback follow Apple's "Capturing system audio
/// with Core Audio taps" documentation.
final class ProcessTapLevelMeter: AudioLevelMeasuring {
    private static let logger = Logger(subsystem: "com.techneissa.pnoe", category: "ProcessTapLevelMeter")
    private let queue = DispatchQueue(label: "com.techneissa.pnoe.level-meter", qos: .userInitiated)
    /// Extra time on top of the listening window before a measurement is given up on.
    private let deadlineMargin: TimeInterval = 0.4
    /// A measurement is running on `queue`. One that never returns (a CoreAudio call blocked on the permission
    /// prompt) keeps this set, so later calls answer `.unavailable` at once instead of queueing behind it.
    private let isMeasuring = OSAllocatedUnfairLock(initialState: false)

    func measure(processes: [AudioProcess], window: TimeInterval) async -> AudioLevelReading {
        let objectIDs = processes.map(\.objectID).filter { $0 != 0 }
        guard !objectIDs.isEmpty else { return .unavailable }
        guard isMeasuring.withLock({ busy -> Bool in
            defer { busy = true }
            return !busy
        }) else { return .unavailable }

        return await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let resumeOnce: @Sendable (AudioLevelReading) -> Void = { reading in
                let first = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: reading) }
            }
            queue.async { [isMeasuring] in
                let reading = Self.listen(to: objectIDs, for: window)
                isMeasuring.withLock { $0 = false }
                resumeOnce(reading)
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + window + deadlineMargin) {
                resumeOnce(.unavailable)
            }
        }
    }

    /// Blocks the private queue for `window`. Everything it creates is destroyed before it returns.
    private static func listen(to processObjectIDs: [AudioObjectID], for window: TimeInterval) -> AudioLevelReading {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.name = "Pnoe level check"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard tapStatus == noErr else {
            logger.info("No tap (status \(tapStatus))")
            return .unavailable
        }
        defer { AudioHardwareDestroyProcessTap(tapID) }

        guard isFloatFormat(ofTap: tapID), let outputUID = defaultOutputDeviceUID() else { return .unavailable }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Pnoe level check",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard aggregateStatus == noErr else {
            logger.info("No aggregate device (status \(aggregateStatus))")
            return .unavailable
        }
        defer { AudioHardwareDestroyAggregateDevice(aggregateID) }

        let meter = OSAllocatedUnfairLock(initialState: PeakMeter())
        var procID: AudioDeviceIOProcID?
        let ioQueue = DispatchQueue(label: "com.techneissa.pnoe.level-meter.io", qos: .userInitiated)
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, input, _, _, _ in
            for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
                guard let data = buffer.mData else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count)
                meter.withLock { $0.add(samples) }
            }
        }
        guard procStatus == noErr, let procID else { return .unavailable }
        defer { AudioDeviceDestroyIOProcID(aggregateID, procID) }

        guard AudioDeviceStart(aggregateID, procID) == noErr else { return .unavailable }
        Thread.sleep(forTimeInterval: window)
        AudioDeviceStop(aggregateID, procID)

        return meter.withLock { $0.reading }
    }

    private static func isFloatFormat(ofTap tapID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format) == noErr else { return false }
        return format.mFormatID == kAudioFormatLinearPCM
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mBitsPerChannel == 32
    }

    private static func defaultOutputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
                == noErr,
            deviceID != kAudioObjectUnknown
        else { return nil }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }
}
