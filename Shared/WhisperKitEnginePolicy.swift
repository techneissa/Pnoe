import Foundation
import IOKit.ps

/// When the WhisperKit engine is used for a WhisperKit model the user picked.
enum WhisperKitUsage: String, CaseIterable, Identifiable, Sendable {
    /// Always run the picked WhisperKit model.
    case on
    /// Never run it; use the fallback model instead.
    case off
    /// WhisperKit on mains power, the fallback model on battery.
    case automatic

    /// Nothing changes behind the user's back until the measurements in issue 38 say otherwise.
    static let `default`: WhisperKitUsage = .on

    static let defaultsKey = "WhisperKitUsage"
    static let fallbackModelDefaultsKey = "WhisperKitFallbackModel"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .on: String(localized: "On")
        case .off: String(localized: "Off")
        case .automatic: String(localized: "Automatic")
        }
    }

    static func stored(in defaults: UserDefaults = .standard) -> WhisperKitUsage {
        defaults.string(forKey: defaultsKey).flatMap(WhisperKitUsage.init(rawValue:)) ?? .default
    }
}

enum PowerSource: Equatable, Sendable {
    case mains
    case battery
}

/// Which engine runs a take for which the user picked a WhisperKit model.
enum WhisperKitEngineChoice: Equatable, Sendable {
    case whisperKit
    case fallback
}

enum WhisperKitEnginePolicy {
    /// The whole battery rule. Anything that is not clearly battery counts as mains, so an
    /// unreadable power state never swaps the model the user picked.
    static func engine(usage: WhisperKitUsage, power: PowerSource) -> WhisperKitEngineChoice {
        switch usage {
        case .on: .whisperKit
        case .off: .fallback
        case .automatic: power == .battery ? .fallback : .whisperKit
        }
    }

    /// The model to run instead of WhisperKit: the user's pick if it is usable, otherwise the first
    /// usable one. Nil when nothing else is installed, in which case the caller keeps WhisperKit.
    static func fallbackModelName(preferred: String?, usable: [String]) -> String? {
        if let preferred, usable.contains(preferred) { return preferred }
        return usable.first
    }
}

/// Reads the power state through IOKit's power-source API, which needs no permission.
enum PowerSourceReader {
    static func current() -> PowerSource {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let providing = IOPSGetProvidingPowerSourceType(info)?.takeRetainedValue() as String?
        else {
            return .mains
        }
        return providing == kIOPSBatteryPowerValue ? .battery : .mains
    }
}
