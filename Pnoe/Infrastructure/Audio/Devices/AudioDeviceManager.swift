import AVFoundation
import CoreAudio
import Foundation
import IOKit.audio
import os

class AudioDeviceManager: ObservableObject {
    let logger = Logger(subsystem: "com.techneissa.pnoe", category: "AudioDeviceManager")
    @Published var availableDevices: [(id: AudioDeviceID, uid: String, name: String)] = []
    /// Hidden input devices: device UID to last known name. Not-connected ones stay listed in settings.
    @Published private(set) var hiddenDeviceNamesByUID: [String: String] = UserDefaults.standard.hiddenAudioDeviceNamesByUID
    @Published var selectedDeviceID: AudioDeviceID?
    @Published var inputMode: AudioInputMode = .custom
    @Published var prioritizedDevices: [PrioritizedDevice] = []
    @Published private(set) var inputChannelsByDevice: [AudioDeviceID: [AudioInputChannel]] = [:]
    @Published private(set) var inputChannelsByDeviceUID: [String: [UInt32]] = UserDefaults.standard.audioInputChannelsByDeviceUID

    @Published var recordingDeviceSession = RecordingDeviceSession()
    var clamshellStateMonitor: ClamshellStateMonitor?
    private var defaultInputDeviceListener: AudioObjectPropertyListenerBlock?
    private let channelDiscoveryQueue = DispatchQueue(
        label: "com.techneissa.pnoe.audioChannelDiscovery", qos: .userInitiated)

    var isRecordingActive: Bool { recordingDeviceSession.isActive }
    var activeRecordingDeviceID: AudioDeviceID? { recordingDeviceSession.activeDeviceID }
    var isClamshellClosed: Bool { clamshellStateMonitor?.isClosed == true }

    /// Connected devices that are not hidden: what every device menu lists and recording may use.
    var visibleDevices: [(id: AudioDeviceID, uid: String, name: String)] {
        availableDevices.filter { hiddenDeviceNamesByUID[$0.uid] == nil }
    }

    /// Devices are connected but all of them are hidden, so recording uses the built-in microphone.
    var allDevicesHidden: Bool {
        !availableDevices.isEmpty && visibleDevices.isEmpty
    }

    func isDeviceHidden(uid: String) -> Bool {
        hiddenDeviceNamesByUID[uid] != nil
    }

    func isDeviceHidden(deviceID: AudioDeviceID) -> Bool {
        availableDevices.first { $0.id == deviceID }.map { isDeviceHidden(uid: $0.uid) } ?? false
    }

    /// What recording uses while every device is hidden; nil when some device is allowed.
    var allHiddenFallback: AllHiddenFallback? {
        recordingDevicePolicy().allHiddenFallback
    }

    var microphoneVisibilityRows: [MicrophoneVisibilityRow] {
        RecordingDevicePolicy.visibilityRows(
            connected: inputDeviceInfos(), hiddenNamesByUID: hiddenDeviceNamesByUID)
    }

    static let shared = AudioDeviceManager()

    init() {
        loadPrioritizedDevices()

        if let savedMode = UserDefaults.standard.audioInputModeRawValue,
            let mode = AudioInputMode(rawValue: savedMode)
        {
            inputMode = mode
        } else {
            inputMode = .systemDefault
        }

        setupRecordingDeviceRouting()

        loadAvailableDevices { [weak self] in
            self?.initializeSelectedDevice()
        }

        setupDeviceChangeNotifications()
        setupDefaultInputDeviceNotifications()
    }

    func getSystemDefaultDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceID
        )

        guard status == noErr, deviceID != 0 else {
            logger.error("Failed to get system default device: \(status, privacy: .public)")
            return nil
        }
        return deviceID
    }

    func getSystemDefaultDeviceName() -> String? {
        guard let deviceID = getSystemDefaultDevice() else { return nil }
        return getDeviceName(deviceID: deviceID)
    }

    private func initializeSelectedDevice() {
        switch inputMode {
        case .systemDefault:
            break
        case .prioritized:
            selectHighestPriorityAvailableDevice()
        case .custom:
            if let savedUID = UserDefaults.standard.selectedAudioDeviceUID {
                let savedModelUID = UserDefaults.standard.selectedAudioDeviceModelUID
                if let found = findAvailableDevice(uid: savedUID, modelUID: savedModelUID) {
                    selectedDeviceID = found.id
                    if found.uid != savedUID || savedModelUID == nil {
                        updateCustomDeviceHints(deviceID: found.id, uid: found.uid)
                    }
                } else {
                    fallbackToDefaultDevice()
                }
            } else {
                fallbackToDefaultDevice()
            }
        }
    }

    private func isDeviceAvailable(_ deviceID: AudioDeviceID) -> Bool {
        return availableDevices.contains { $0.id == deviceID }
    }

    private func fallbackToDefaultDevice() {
        guard let newDeviceID = findBestAvailableDevice() else {
            logger.error("No input devices available!")
            selectedDeviceID = nil
            notifyDeviceChange()
            return
        }
        activateDevice(id: newDeviceID)
    }

    private func activateDevice(id: AudioDeviceID) {
        selectedDeviceID = id
        notifyDeviceChange()
    }

    func loadAvailableDevices(completion: (() -> Void)? = nil) {
        var propertySize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var result = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize
        )

        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size

        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        result = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceIDs
        )

        if result != noErr {
            logger.error("Error getting audio devices: \(result, privacy: .public)")
            return
        }

        let devices = deviceIDs.compactMap { deviceID -> (id: AudioDeviceID, uid: String, name: String)? in
            guard let name = getDeviceName(deviceID: deviceID),
                let uid = getDeviceUID(deviceID: deviceID),
                isValidInputDevice(deviceID: deviceID)
            else {
                return nil
            }
            return (id: deviceID, uid: uid, name: name)
        }
        channelDiscoveryQueue.async { [weak self] in
            let inputChannels = Dictionary(uniqueKeysWithValues: devices.map {
                ($0.id, AudioDeviceConfiguration.inputChannels(deviceID: $0.id))
            })

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.availableDevices = devices.map { ($0.id, $0.uid, $0.name) }
                self.inputChannelsByDevice = inputChannels
                self.refreshHiddenDeviceNames()
                if let currentID = self.selectedDeviceID,
                    !devices.contains(where: { $0.id == currentID }) || self.isDeviceExcluded(deviceID: currentID)
                {
                    if !self.isRecordingActive {
                        if self.inputMode == .prioritized {
                            self.selectHighestPriorityAvailableDevice()
                        } else {
                            self.fallbackToDefaultDevice()
                        }
                    }
                }
                completion?()
            }
        }
    }

    func getDeviceName(deviceID: AudioDeviceID) -> String? {
        let name = getCFStringDeviceProperty(
            deviceID: deviceID,
            selector: kAudioDevicePropertyDeviceNameCFString)
        return name as String?
    }

    func selectedInputChannels(for deviceID: AudioDeviceID) -> [UInt32]? {
        guard !isInternalMicrophone(deviceID),
              let uid = availableDevices.first(where: { $0.id == deviceID })?.uid else { return nil }
        return inputChannelsByDeviceUID[uid]
    }

    func setInputChannels(_ channels: [UInt32]?, for deviceID: AudioDeviceID) {
        // A capture already in progress must keep its format and channel map until it stops.
        guard !isRecordingActive,
              let uid = availableDevices.first(where: { $0.id == deviceID })?.uid else { return }
        if let channels {
            let channelCount = UInt32(inputChannelsByDevice[deviceID]?.count ?? 0)
            guard let valid = AudioInputChannelSelection.validatedChannels(channels, deviceChannelCount: channelCount) else {
                return
            }
            inputChannelsByDeviceUID[uid] = valid
        } else {
            inputChannelsByDeviceUID.removeValue(forKey: uid)
        }
        UserDefaults.standard.audioInputChannelsByDeviceUID = inputChannelsByDeviceUID
        notifyDeviceChange()
    }

    func isValidInputDevice(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0
        var result = AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &propertySize
        )

        if result != noErr {
            logger.error(
                "Error checking input capability for device \(deviceID, privacy: .public): \(result, privacy: .public)")
            return false
        }

        let bufferListStorage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(propertySize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferListStorage.deallocate() }
        let bufferList = bufferListStorage.assumingMemoryBound(to: AudioBufferList.self)

        result = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            bufferList
        )

        if result != noErr {
            logger.error(
                "Error getting stream configuration for device \(deviceID, privacy: .public): \(result, privacy: .public)"
            )
            return false
        }

        return UnsafeMutableAudioBufferListPointer(bufferList).contains {
            $0.mNumberChannels > 0
        }
    }

    func selectDevice(id: AudioDeviceID) {
        if let deviceToSelect = visibleDevices.first(where: { $0.id == id }) {
            let uid = deviceToSelect.uid
            let modelUID = getDeviceModelUID(deviceID: id)
            DispatchQueue.main.async {
                self.selectedDeviceID = id
                self.updateCustomDeviceHints(deviceID: id, uid: uid, modelUID: modelUID)
                self.notifyDeviceChange()
            }
        } else {
            logger.error("Attempted to select unavailable device: \(id, privacy: .public)")
            fallbackToDefaultDevice()
        }
    }

    func selectDeviceAndSwitchToCustomMode(id: AudioDeviceID) {
        if let deviceToSelect = visibleDevices.first(where: { $0.id == id }) {
            let uid = deviceToSelect.uid
            let modelUID = getDeviceModelUID(deviceID: id)
            DispatchQueue.main.async {
                self.inputMode = .custom
                self.selectedDeviceID = id
                UserDefaults.standard.audioInputModeRawValue = AudioInputMode.custom.rawValue
                self.updateCustomDeviceHints(deviceID: id, uid: uid, modelUID: modelUID)
                self.notifyDeviceChange()
            }
        } else {
            logger.error("Attempted to select unavailable device: \(id, privacy: .public)")
            fallbackToDefaultDevice()
        }
    }

    func selectInputMode(_ mode: AudioInputMode) {
        inputMode = mode
        UserDefaults.standard.audioInputModeRawValue = mode.rawValue

        switch mode {
        case .systemDefault:
            break
        case .custom:
            if selectedDeviceID == nil {
                if let firstDevice = visibleDevices.first {
                    selectDevice(id: firstDevice.id)
                }
            }
        case .prioritized:
            if selectedDeviceID == nil {
                selectHighestPriorityAvailableDevice()
            }
        }

        notifyDeviceChange()
    }

    /// Hides or shows a device by UID. Hiding the selected device switches the selection at once;
    /// during a recording the change waits for the next one.
    func setDevice(uid: String, name: String, hidden: Bool) {
        guard isDeviceHidden(uid: uid) != hidden else { return }
        if hidden {
            hiddenDeviceNamesByUID[uid] = name
        } else {
            hiddenDeviceNamesByUID.removeValue(forKey: uid)
        }
        UserDefaults.standard.hiddenAudioDeviceNamesByUID = hiddenDeviceNamesByUID
        logger.notice("Input device \(hidden ? "hidden" : "shown", privacy: .public)")
        if allDevicesHidden {
            logger.notice("Every input device is hidden: recording uses the built-in microphone")
        }
        guard !isRecordingActive else {
            notifyDeviceChange()
            return
        }
        reconcileSelectionAfterVisibilityChange()
    }

    /// Moves the selection off a hidden device, and back to the saved choice once it is shown again.
    func reconcileSelectionAfterVisibilityChange() {
        switch inputMode {
        case .systemDefault:
            notifyDeviceChange()
        case .prioritized:
            selectHighestPriorityAvailableDevice()
        case .custom:
            reconcileCustomDeviceAfterListChange()
            notifyDeviceChange()
        }
    }

    /// Hidden and not the last resort: with every device hidden the built-in microphone stays selectable.
    func isDeviceExcluded(deviceID: AudioDeviceID) -> Bool {
        isDeviceHidden(deviceID: deviceID) && !allDevicesHidden
    }

    var selectedDeviceIsExcluded: Bool {
        selectedDeviceID.map(isDeviceExcluded(deviceID:)) ?? false
    }

    private func refreshHiddenDeviceNames() {
        var updated = hiddenDeviceNamesByUID
        for device in availableDevices where updated[device.uid] != nil && updated[device.uid] != device.name {
            updated[device.uid] = device.name
        }
        guard updated != hiddenDeviceNamesByUID else { return }
        hiddenDeviceNamesByUID = updated
        UserDefaults.standard.hiddenAudioDeviceNamesByUID = updated
    }

    func inputDeviceInfos() -> [InputDeviceInfo] {
        availableDevices.map {
            InputDeviceInfo(
                id: $0.id, uid: $0.uid, name: $0.name, modelUID: getDeviceModelUID(deviceID: $0.id),
                isInternalMicrophone: isInternalMicrophone($0.id))
        }
    }

    func recordingDevicePolicy() -> RecordingDevicePolicy {
        RecordingDevicePolicy(
            mode: inputMode,
            devices: inputDeviceInfos(),
            hiddenUIDs: Set(hiddenDeviceNamesByUID.keys),
            systemDefaultID: getSystemDefaultDevice(),
            customUID: UserDefaults.standard.selectedAudioDeviceUID ?? "",
            customModelUID: UserDefaults.standard.selectedAudioDeviceModelUID,
            selectedDeviceID: selectedDeviceID,
            prioritized: prioritizedDevices,
            isClamshellClosed: isClamshellClosed)
    }

    private func loadPrioritizedDevices() {
        if let data = UserDefaults.standard.prioritizedDevicesData,
            let devices = try? JSONDecoder().decode([PrioritizedDevice].self, from: data)
        {
            prioritizedDevices = devices
        }
    }

    func savePrioritizedDevices() {
        if let data = try? JSONEncoder().encode(prioritizedDevices) {
            UserDefaults.standard.prioritizedDevicesData = data
        }
    }

    func addPrioritizedDevice(uid: String, name: String) {
        guard !prioritizedDevices.contains(where: { $0.id == uid }) else { return }
        let modelUID = availableDevices.first(where: { $0.uid == uid })
            .flatMap { getDeviceModelUID(deviceID: $0.id) }
        let nextPriority = (prioritizedDevices.map { $0.priority }.max() ?? -1) + 1
        let device = PrioritizedDevice(id: uid, name: name, priority: nextPriority, modelUID: modelUID)
        prioritizedDevices.append(device)
        savePrioritizedDevices()
    }

    func removePrioritizedDevice(id: String) {
        let wasSelected = selectedDeviceID == availableDevices.first(where: { $0.uid == id })?.id
        prioritizedDevices.removeAll { $0.id == id }

        let updatedDevices = prioritizedDevices.enumerated().map { index, device in
            PrioritizedDevice(id: device.id, name: device.name, priority: index, modelUID: device.modelUID)
        }

        prioritizedDevices = updatedDevices
        savePrioritizedDevices()

        if wasSelected && inputMode == .prioritized {
            selectHighestPriorityAvailableDevice()
        }
    }

    func updatePriorities(devices: [PrioritizedDevice]) {
        prioritizedDevices = devices
        savePrioritizedDevices()

        if inputMode == .prioritized {
            selectHighestPriorityAvailableDevice()
        }

        notifyDeviceChange()
    }

    private func selectHighestPriorityAvailableDevice() {
        let sortedDevices = prioritizedDevices.sorted { $0.priority < $1.priority }

        for saved in sortedDevices {
            guard let found = findAvailableDevice(uid: saved.id, modelUID: saved.modelUID) else {
                continue
            }
            guard isDeviceUsableForRecording(found.id) else { continue }
            selectedDeviceID = found.id
            if found.uid != saved.id || saved.modelUID == nil {
                rebindPrioritizedDevice(
                    savedUID: saved.id, newUID: found.uid, newModelUID: getDeviceModelUID(deviceID: found.id))
            }
            notifyDeviceChange()
            return
        }

        fallbackToDefaultDevice()
    }

    private func setupDeviceChangeNotifications() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)

        let status = AudioObjectAddPropertyListener(
            systemObjectID,
            &address,
            { (_, _, _, userData) -> OSStatus in
                let manager = Unmanaged<AudioDeviceManager>.fromOpaque(userData!).takeUnretainedValue()
                DispatchQueue.main.async {
                    manager.handleDeviceListChange()
                }
                return noErr
            },
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        if status != noErr {
            logger.error("Failed to add device change listener: \(status, privacy: .public)")
        }
    }

    private func handleDeviceListChange() {
        loadAvailableDevices { [weak self] in
            guard let self = self else { return }

            if self.isRecordingActive {
                guard let activeDeviceID = self.activeRecordingDeviceID,
                    !self.isOperationalInputDevice(activeDeviceID)
                else {
                    return
                }
                self.requestRecordingDeviceChange(reason: .deviceUnavailable)
                return
            }

            if self.inputMode == .systemDefault {
                self.notifyDeviceChange()
                return
            }

            if self.inputMode == .prioritized {
                self.selectHighestPriorityAvailableDevice()
            } else if self.inputMode == .custom {
                self.reconcileCustomDeviceAfterListChange()
            }
        }
    }

    private func setupDefaultInputDeviceNotifications() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.inputMode == .systemDefault else { return }
            self.loadAvailableDevices { [weak self] in
                guard let self, self.inputMode == .systemDefault else { return }
                self.notifyDeviceChange()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, listener
        )
        if status == noErr {
            defaultInputDeviceListener = listener
        } else {
            logger.error("Failed to observe default input changes: \(status, privacy: .public)")
        }
    }

    private func getDeviceUID(deviceID: AudioDeviceID) -> String? {
        let uid = getCFStringDeviceProperty(
            deviceID: deviceID,
            selector: kAudioDevicePropertyDeviceUID)
        return uid as String?
    }

    func getDeviceModelUID(deviceID: AudioDeviceID) -> String? {
        let uid = getCFStringDeviceProperty(
            deviceID: deviceID,
            selector: kAudioDevicePropertyModelUID)
        return uid as String?
    }

    /// Finds a connected device that is not hidden, by UID and then by model UID. A saved device
    /// that is connected but hidden finds nothing: see `RecordingDevicePolicy.find`.
    func findAvailableDevice(uid: String, modelUID: String?) -> (id: AudioDeviceID, uid: String, name: String)?
    {
        guard let found = RecordingDevicePolicy.find(
            uid: uid, modelUID: modelUID, in: inputDeviceInfos(), hiddenUIDs: Set(hiddenDeviceNamesByUID.keys))
        else { return nil }
        return availableDevices.first { $0.id == found.id }
    }

    private func rebindPrioritizedDevice(savedUID: String, newUID: String, newModelUID: String?) {
        prioritizedDevices.removeAll { $0.id == newUID && $0.id != savedUID }
        prioritizedDevices = prioritizedDevices.map { device in
            guard device.id == savedUID else { return device }
            return PrioritizedDevice(
                id: newUID, name: device.name, priority: device.priority, modelUID: newModelUID ?? device.modelUID)
        }
        savePrioritizedDevices()
    }

    private func updateCustomDeviceHints(deviceID: AudioDeviceID, uid: String, modelUID: String? = nil) {
        UserDefaults.standard.selectedAudioDeviceUID = uid
        UserDefaults.standard.selectedAudioDeviceModelUID = modelUID ?? getDeviceModelUID(deviceID: deviceID)
    }

    private func reconcileCustomDeviceAfterListChange() {
        let savedUID = UserDefaults.standard.selectedAudioDeviceUID ?? ""
        let savedModelUID = UserDefaults.standard.selectedAudioDeviceModelUID

        if let desired = findAvailableDevice(uid: savedUID, modelUID: savedModelUID) {
            if selectedDeviceID != desired.id {
                selectedDeviceID = desired.id
                if desired.uid != savedUID || savedModelUID == nil {
                    updateCustomDeviceHints(deviceID: desired.id, uid: desired.uid)
                }
                notifyDeviceChange()
            } else if savedModelUID == nil {
                updateCustomDeviceHints(deviceID: desired.id, uid: desired.uid)
            }
        } else if let currentID = selectedDeviceID, !isDeviceAvailable(currentID) || isDeviceExcluded(deviceID: currentID) {
            fallbackToDefaultDevice()
        }
    }

    deinit {
        if let defaultInputDeviceListener {
            var defaultAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &defaultAddress, .main, defaultInputDeviceListener
            )
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            { (_, _, _, userData) -> OSStatus in
                return noErr
            },
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

    }

    private func createPropertyAddress(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        return AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
    }

    private func getCFStringDeviceProperty(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> CFString? {
        guard deviceID != 0 else { return nil }

        var address = createPropertyAddress(selector: selector, scope: scope)
        var propertySize = UInt32(MemoryLayout<CFString>.size)
        var property = "" as CFString

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &property
        )

        if status != noErr {
            logger.error(
                "Failed to get device property \(selector, privacy: .public) for device \(deviceID, privacy: .public): \(status, privacy: .public)"
            )
            return nil
        }

        return property
    }

    func getUInt32DeviceProperty(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> UInt32? {
        guard deviceID != 0 else { return nil }

        var address = createPropertyAddress(selector: selector, scope: scope)
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        var property: UInt32 = 0

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &property
        )
        guard status == noErr else { return nil }
        return property
    }

    /// The MacBook's internal microphone is physically disconnected when the lid closes.
    /// A headset-jack microphone also uses the built-in codec, so transport alone cannot identify lid-dependent inputs.
    func isInternalMicrophone(_ deviceID: AudioDeviceID) -> Bool {
        guard
            getUInt32DeviceProperty(
                deviceID: deviceID,
                selector: kAudioDevicePropertyTransportType
            ) == kAudioDeviceTransportTypeBuiltIn
        else {
            return false
        }

        let uid = getDeviceUID(deviceID: deviceID)
        let dataSource = getUInt32DeviceProperty(
            deviceID: deviceID,
            selector: kAudioDevicePropertyDataSource,
            scope: kAudioDevicePropertyScopeInput
        )
        let internalMicrophoneSource = UInt32(kIOAudioSelectorControlSelectionValueInternalMicrophone)
        let externalMicrophoneSource = UInt32(kIOAudioSelectorControlSelectionValueExternalMicrophone)

        if dataSource == externalMicrophoneSource {
            return false
        }
        if dataSource == internalMicrophoneSource {
            return true
        }

        // Older Apple drivers may not implement data-source controls. Keep the known system
        // device UIDs only as a final compatibility fallback and fail open for unknown inputs.
        if uid == "BuiltInHeadphoneInputDevice" {
            return false
        }
        return uid == "BuiltInMicrophoneDevice"
    }

    func notifyDeviceChange() {
        NotificationCenter.default.post(name: NSNotification.Name("AudioDeviceChanged"), object: nil)
    }
}
