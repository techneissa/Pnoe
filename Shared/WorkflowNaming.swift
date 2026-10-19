import Foundation

enum WorkflowNaming {
    /// `base` when it is free, otherwise `base 2`, `base 3`, ... using the first free number.
    static func uniqueName(_ base: String, existing: Set<String>) -> String {
        guard existing.contains(base) else { return base }
        var suffix = 2
        while existing.contains("\(base) \(suffix)") {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }
}
