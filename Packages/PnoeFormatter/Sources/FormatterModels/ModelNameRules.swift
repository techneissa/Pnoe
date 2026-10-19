import Foundation

/// Name rules shared by every source.
enum ModelNameRules {
    private static let embeddingMarkers = ["embed", "bge", "minilm", "rerank"]

    /// Embedding and reranker models cannot format text. `family` is Ollama's `details.family` or `families`.
    static func isEmbeddingModel(name: String, families: [String] = []) -> Bool {
        let lowered = name.lowercased()
        if embeddingMarkers.contains(where: lowered.contains) { return true }
        // Encoder families (bert, nomic-bert, xlm-roberta) are embedding models.
        return families.contains { family in
            let lowered = family.lowercased()
            return lowered.contains("bert") || lowered.contains("embed") || lowered.contains("bge")
        }
    }

    /// Vision projector and draft (speculative decoding) files sit beside the real model and are not one.
    static func isAuxiliaryGGUF(fileName: String) -> Bool {
        let lowered = fileName.lowercased()
        return lowered.contains("mmproj") || lowered.contains("draft")
    }

    /// `Q4_K_M`, `IQ3_XS`, `Q8_0`, `F16`, `BF16` from a file name such as `gemma-4-E2B-it-Q4_K_M.gguf`.
    static func ggufQuantization(fileName: String) -> String? {
        let pattern = #"(?<![A-Za-z0-9])((?:IQ|Q)\d(?:_[A-Za-z0-9]+)*|BF16|F16|F32)(?![A-Za-z0-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(fileName.startIndex..., in: fileName)
        guard let match = regex.firstMatch(in: fileName, range: range),
              let swiftRange = Range(match.range(at: 1), in: fileName)
        else { return nil }
        return fileName[swiftRange].uppercased()
    }

    /// The most shards a split model may claim. Real models have a few dozen; a bigger number in a file name is
    /// not a real split and would only make the scanner stat thousands of missing files.
    static let maximumShardCount = 999

    /// True when the name ends in `-NNNNN-of-NNNNN.gguf`, valid or not.
    static func hasShardSuffix(fileName: String) -> Bool {
        fileName.range(of: shardPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// `-00002-of-00003` shard suffix: the shard number and the shard count. Nil when the name has no such suffix
    /// or its numbers cannot be real (`-00001-of-00000`, shard above count, count above `maximumShardCount`).
    static func ggufShard(fileName: String) -> (index: Int, count: Int)? {
        guard let regex = try? NSRegularExpression(pattern: shardPattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(fileName.startIndex..., in: fileName)
        guard let match = regex.firstMatch(in: fileName, range: range),
              let first = Range(match.range(at: 1), in: fileName),
              let second = Range(match.range(at: 2), in: fileName),
              let index = Int(fileName[first]), let count = Int(fileName[second]),
              count >= 1, count <= maximumShardCount, index >= 1, index <= count
        else { return nil }
        return (index, count)
    }

    private static let shardPattern = #"-(\d{5})-of-(\d{5})\.gguf$"#

    /// MLX conversions: the `mlx-community` org, or a name that says MLX or a bit width, and (checked by the
    /// caller) a `quantization` entry in `config.json`.
    static func looksLikeMLXName(org: String?, name: String) -> Bool {
        if org?.lowercased() == "mlx-community" { return true }
        let lowered = name.lowercased()
        if lowered.contains("mlx") { return true }
        return lowered.range(of: #"(^|[^a-z0-9])\d{1,2}bit($|[^a-z0-9])"#, options: .regularExpression) != nil
    }
}
