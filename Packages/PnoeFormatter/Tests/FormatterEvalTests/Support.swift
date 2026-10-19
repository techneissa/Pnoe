import FormatterCore
import Foundation
@testable import FormatterEvalKit

enum Fixtures {
    /// The package's `Eval` folder, found from this file.
    static let data = EvalData(
        directory: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Eval")
    )

    static let cases: [EvalCase] = {
        do { return try TestSet.load(from: data.testsetURL) } catch { fatalError("testset.jsonl: \(error)") }
    }()

    static let replay: ReplayFile = {
        do { return try ReplayFile.load(from: data.round1OutputsURL) } catch { fatalError("outputs.json: \(error)") }
    }()

    static func testCase(_ id: String) -> EvalCase {
        guard let found = cases.first(where: { $0.id == id }) else { fatalError("no case \(id)") }
        return found
    }
}
