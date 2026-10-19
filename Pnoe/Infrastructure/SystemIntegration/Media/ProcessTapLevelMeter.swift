import AudioToolbox
import CoreAudio
import Foundation
import os

/// Reads the level of some processes' audio through CoreAudio process taps (macOS 14.2 and later).
///
/// A tap listens without changing what the user hears (`muteBehavior` is `.unmuted`), for the players and for
/// Pnoe's own start sound alike. The first tap makes macOS ask for the System Audio Recording permission, which is
/// why `PlaybackController` uses this only when the user turned the level check on. Each tap lives for one listening
/// session and is private to Pnoe: no other app sees it.
///
/// The tap, the private aggregate device that carries it and the IO callback follow Apple's "Capturing system audio
/// with Core Audio taps" documentation. One tap and one aggregate device per group of processes keeps the players'
/// samples and Pnoe's own apart without relying on the order of buffers in a shared callback.
final class ProcessTapLevelMeter: AudioLevelMeasuring {
    private static let logger = Logger(subsystem: "com.techneissa.pnoe", category: "ProcessTapLevelMeter")
    private let queue = DispatchQueue(label: "com.techneissa.pnoe.level-meter", qos: .userInitiated)
    /// Extra time on top of the listening window before a measurement is given up on.
    private let deadlineMargin: TimeInterval = 0.4
    /// A measurement is running on `queue`. One that never returns (a CoreAudio call blocked on the permission
    /// prompt) keeps this set, so later calls answer `.unavailable` at once instead of queueing behind it.
    private let isMeasuring = OSAllocatedUnfairLock(initialState: false)

    func measure(processes: [AudioProcess], includingOwnProcess: Bool, window: TimeInterval) async
        -> AudioLevelMeasurement
    {
        let unavailable = AudioLevelMeasurement.unavailable(includingOwn: includingOwnProcess)
        let objectIDs = processes.map(\.objectID).filter { $0 != 0 }
        guard !objectIDs.isEmpty else { return unavailable }
        guard
            isMeasuring.withLock({ busy -> Bool in
                defer { busy = true }
                return !busy
            })
        else { return unavailable }

        return await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let resumeOnce: @Sendable (AudioLevelMeasurement) -> Void = { measurement in
                let first = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: measurement) }
            }
            queue.async { [isMeasuring] in
                let measurement = Self.listen(
                    to: objectIDs, includingOwnProcess: includingOwnProcess, window: window)
                isMeasuring.withLock { $0 = false }
                resumeOnce(measurement)
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + window + deadlineMargin) {
                resumeOnce(unavailable)
            }
        }
    }

    /// Blocks the private queue until `ListeningPlan` is satisfied or `window` is over. Every tap it creates is
    /// destroyed before it returns.
    private static func listen(
        to processObjectIDs: [AudioObjectID], includingOwnProcess: Bool, window: TimeInterval
    ) -> AudioLevelMeasurement {
        guard let players = TapListener(processObjectIDs: processObjectIDs) else {
            return .unavailable(includingOwn: includingOwnProcess)
        }
        defer { players.stop() }

        var own: TapListener?
        defer { own?.stop() }

        let started = ProcessInfo.processInfo.systemUptime
        var lastOwnAttempt = -Double.infinity
        while true {
            let elapsed = ProcessInfo.processInfo.systemUptime - started

            // Pnoe has a process object only once it has an audio stream open, which the start sound may be
            // about to create, so the lookup is retried while the window lasts.
            if includingOwnProcess, own == nil, elapsed - lastOwnAttempt >= 0.05 {
                lastOwnAttempt = elapsed
                if let object = processObject(forPID: ProcessInfo.processInfo.processIdentifier) {
                    own = TapListener(processObjectIDs: [object])
                }
            }

            let playersReading = players.reading
            let ownReading: AudioLevelReading? = includingOwnProcess ? (own?.reading ?? .unavailable) : nil
            if ListeningPlan.isDone(elapsed: elapsed, window: window, players: playersReading, own: ownReading) {
                return AudioLevelMeasurement(players: playersReading, own: ownReading)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    /// One tap on some processes, the private aggregate device that carries it, and a running peak of its samples.
    private final class TapListener {
        private let tapID: AudioObjectID
        private let aggregateID: AudioObjectID
        private let procID: AudioDeviceIOProcID
        private let ioQueue = DispatchQueue(label: "com.techneissa.pnoe.level-meter.io", qos: .userInitiated)
        private let meter = OSAllocatedUnfairLock(initialState: PeakMeter())
        private var isStopped = false

        init?(processObjectIDs: [AudioObjectID]) {
            let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
            description.name = "Pnoe level check"
            description.uuid = UUID()
            description.isPrivate = true
            description.muteBehavior = .unmuted

            var tapID = AudioObjectID(kAudioObjectUnknown)
            let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
            guard tapStatus == noErr else {
                ProcessTapLevelMeter.logger.info("No tap (status \(tapStatus))")
                return nil
            }
            guard ProcessTapLevelMeter.isFloatFormat(ofTap: tapID),
                let outputUID = ProcessTapLevelMeter.defaultOutputDeviceUID()
            else {
                AudioHardwareDestroyProcessTap(tapID)
                return nil
            }

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
                ProcessTapLevelMeter.logger.info("No aggregate device (status \(aggregateStatus))")
                AudioHardwareDestroyProcessTap(tapID)
                return nil
            }

            let meter = self.meter
            var procID: AudioDeviceIOProcID?
            let procStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, input, _, _, _ in
                for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
                    guard let data = buffer.mData else { continue }
                    let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count)
                    meter.withLock { $0.add(samples) }
                }
            }
            guard procStatus == noErr, let procID else {
                AudioHardwareDestroyAggregateDevice(aggregateID)
                AudioHardwareDestroyProcessTap(tapID)
                return nil
            }
            guard AudioDeviceStart(aggregateID, procID) == noErr else {
                AudioDeviceDestroyIOProcID(aggregateID, procID)
                AudioHardwareDestroyAggregateDevice(aggregateID)
                AudioHardwareDestroyProcessTap(tapID)
                return nil
            }

            self.tapID = tapID
            self.aggregateID = aggregateID
            self.procID = procID
        }

        var reading: AudioLevelReading { meter.withLock { $0.reading } }

        func stop() {
            guard !isStopped else { return }
            isStopped = true
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
        }
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
