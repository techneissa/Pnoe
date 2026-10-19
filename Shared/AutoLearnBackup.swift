import Foundation

/// The Auto Learn repeat settings as they are written to a settings backup. Backups made before
/// these settings existed have neither value; importing them leaves the current settings alone.
struct AutoLearnBackupSettings: Codable, Equatable, Sendable {
    var repeatThreshold: Int?
    var usesAIReview: Bool?

    init(repeatThreshold: Int? = nil, usesAIReview: Bool? = nil) {
        self.repeatThreshold = repeatThreshold
        self.usesAIReview = usesAIReview
    }

    /// Reads the saved values; a missing or unknown threshold is exported as the default.
    static func current(
        in defaults: UserDefaults, thresholdKey: String, usesAIReviewKey: String
    ) -> AutoLearnBackupSettings {
        let threshold =
            AutoLearnRepeatThreshold(rawValue: defaults.integer(forKey: thresholdKey)) ?? .default
        return AutoLearnBackupSettings(
            repeatThreshold: threshold.rawValue, usesAIReview: defaults.bool(forKey: usesAIReviewKey))
    }

    /// Writes the values the file has. A threshold outside the supported counts is ignored.
    func apply(to defaults: UserDefaults, thresholdKey: String, usesAIReviewKey: String) {
        if let repeatThreshold, let threshold = AutoLearnRepeatThreshold(rawValue: repeatThreshold) {
            defaults.set(threshold.rawValue, forKey: thresholdKey)
        }
        if let usesAIReview {
            defaults.set(usesAIReview, forKey: usesAIReviewKey)
        }
    }
}
