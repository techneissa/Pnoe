import AudioToolbox
import CoreAudio
import Foundation
import os

/// Reads the level of some processes' audio through CoreAudio process taps (macOS 14.2 and later).
///
/// A tap listens without changing what the user hears (`muteBehavior` is `.unmuted`). The first tap makes macOS ask for the System Audio Recording permission, which is
/// why `PlaybackController` asks for it when the user turns pausing media on. Each tap lives for one listening
/// session and is private to Pnoe: no other app sees it.
///
/// The tap, the private aggregate device that carries it and the IO callback follow Apple's "Capturing system audio
/// with Core Audio taps" documentation. One tap and one aggregate device carry the players' mix.
final class ProcessTapLevelMeter: AudioLevelMeasuring {
    private static let logger = Logger(subsystem: "com.techneissa.pnoe", category: "ProcessTapLevelMeter")
    private let queue = DispatchQueue(label: "com.techneissa.pnoe.level-meter", qos: .userInitiated)
    /// Extra time on top of the listening window before a measurement is given up on.
    private let deadlineMargin: TimeInterval = 0.4
    /// A measurement is running on `queue`. One that never returns (a CoreAudio call blocked on the permission
    /// prompt) keeps this set, so later calls answer `.unavailable` at once instead of queueing behind it.
    private let isMeasuring = OSAllocatedUnfairLock(initialState: false)

    /// Without a prompt. `TCCAccessPreflight` is the only way to ask the System Audio Recording permission without
    /// creating a tap, which can deliver silence instead of failing when the permission is missing. It is a private
    /// symbol, looked up at run time; when it is not there, the answer is "not granted".
    func hasPermission() async -> Bool {
        Self.tcc.preflight?(Self.tccService, nil) == 0
    }

    /// Shows the macOS prompt when the permission is undecided, then makes and destroys one tap on the whole system
    /// mix to prove that taps work.
    func requestPermission() async -> Bool {
        guard let preflight = Self.tcc.preflight, let request = Self.tcc.request else { return false }
        if preflight(Self.tccService, nil) != 0 {
            let granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                request(Self.tccService, nil) { continuation.resume(returning: $0) }
            }
            guard granted else { return false }
        }
        return await withCheckedContinuation { continuation in
            queue.async {
                let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
                description.name = "Pnoe permission check"
                description.uuid = UUID()
                description.isPrivate = true
                description.muteBehavior = .unmuted
                var tapID = AudioObjectID(kAudioObjectUnknown)
                let created = AudioHardwareCreateProcessTap(description, &tapID) == noErr
                if created { AudioHardwareDestroyProcessTap(tapID) }
                continuation.resume(returning: created)
            }
        }
    }

    private static let tccService = "kTCCServiceAudioCapture" as CFString
    private static let tcc: (
        preflight: (@convention(c) (CFString, CFDictionary?) -> Int)?,
        request: (@convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void)?
    ) = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW) else {
            return (nil, nil)
        }
        let preflight = dlsym(handle, "TCCAccessPreflight").map {
            unsafeBitCast($0, to: (@convention(c) (CFString, CFDictionary?) -> Int).self)
        }
        let request = dlsym(handle, "TCCAccessRequest").map {
            unsafeBitCast(
                $0, to: (@convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void).self)
        }
        return (preflight, request)
    }()

    func measure(processes: [AudioProcess], window: TimeInterval) async -> AudioLevelMeasurement {
        let objectIDs = processes.map(\.objectID).filter { $0 != 0 }
        guard !objectIDs.isEmpty else { return .skipped }
        guard
            isMeasuring.withLock({ busy -> Bool in
                defer { busy = true }
                return !busy
            })
        else { return .skipped }

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
                let measurement = Self.listen(to: objectIDs, window: window)
                isMeasuring.withLock { $0 = false }
                resumeOnce(measurement)
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + window + deadlineMargin) {
                resumeOnce(.skipped)
            }
        }
    }

    /// Blocks the private queue until `ListeningPlan` is satisfied or `window` is over. The tap it creates is
    /// destroyed before it returns. No tap is `.unavailable`; a tap that delivered no samples is `.skipped`.
    private static func listen(to processObjectIDs: [AudioObjectID], window: TimeInterval) -> AudioLevelMeasurement {
        guard let players = TapListener(processObjectIDs: processObjectIDs) else { return .unavailable }
        defer { players.stop() }

        let started = ProcessInfo.processInfo.systemUptime
        while true {
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            let reading = players.reading
            if ListeningPlan.isDone(elapsed: elapsed, window: window, players: reading) {
                return AudioLevelMeasurement(players: reading == .unavailable ? .skipped : reading)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
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
