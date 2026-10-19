import Foundation

/// A workflow the Playground can run: just what the screen needs, so the screen and its tests hold no
/// app types.
struct PlaygroundWorkflow: Identifiable, Equatable {
    let id: UUID
    let name: String
    /// An SF Symbol name for the picker row, or nil.
    var symbol: String?
    /// The Pnoe template the workflow's prompt comes from, or nil for a custom prompt.
    var template: LocalWorkflowTemplate?

    /// Cleaned Text is held to the speaker's words by the checks, so it is the one whose saved pairs the
    /// eval harness can score.
    var isCleanedText: Bool { template == .cleanedText }
}

/// What one run produced.
struct PlaygroundOutcome: Equatable {
    let output: String
    let duration: TimeInterval
    /// Cleaned Text only: the `FallbackReason` code when the plain transcript was used instead of the model's text.
    var fallbackReason: String?
}

/// The state behind the Playground: type or paste a sample, run a workflow, see input and result side by side,
/// and save the pair as an example. The model call itself comes in as `runner`.
@MainActor
final class WorkflowPlaygroundModel: ObservableObject {
    typealias Runner = @MainActor (_ text: String, _ workflow: PlaygroundWorkflow) async throws -> PlaygroundOutcome

    struct Finished: Equatable {
        /// The text and workflow that were run, which a saved pair keeps even if the box changes afterwards.
        let input: String
        let workflow: PlaygroundWorkflow
        let outcome: PlaygroundOutcome
    }

    enum Phase: Equatable {
        case idle
        case running
        case finished(Finished)
        case failed(String)
    }

    @Published var workflows: [PlaygroundWorkflow]
    @Published var selectedWorkflowID: UUID?
    @Published var input = ""
    @Published private(set) var phase: Phase = .idle
    /// The result as the speaker wants it to read; starts as the workflow's own output.
    @Published var editedResult = ""
    @Published private(set) var examples: [PlaygroundExample] = []
    @Published private(set) var unreadableLines = 0
    /// A short line after a save, delete or export, or the reason one failed.
    @Published private(set) var notice: String?

    private let runner: Runner
    private let store: PlaygroundExampleStore
    private var runTask: Task<Void, Never>?
    private var runCounter = 0

    init(workflows: [PlaygroundWorkflow], store: PlaygroundExampleStore, runner: @escaping Runner) {
        self.workflows = workflows
        self.store = store
        self.runner = runner
        selectedWorkflowID = workflows.first?.id
        reload()
    }

    var selectedWorkflow: PlaygroundWorkflow? { workflows.first { $0.id == selectedWorkflowID } }

    var canRun: Bool {
        selectedWorkflow != nil && !trimmedInput.isEmpty && phase != .running
    }

    var finished: Finished? {
        if case .finished(let value) = phase { return value }
        return nil
    }

    /// True once the speaker has changed the result away from what the workflow wrote.
    var resultWasEdited: Bool {
        guard let finished else { return false }
        return editedResult != finished.outcome.output
    }

    /// The sentence for a Cleaned Text run that pasted the plain transcript, or nil.
    var fallbackSentence: String? {
        guard let finished, finished.workflow.isCleanedText, let code = finished.outcome.fallbackReason else { return nil }
        return PlaygroundFallbackText.sentence(forCode: code)
    }

    /// The workflows whose saved pairs the eval harness scores are Cleaned Text only; saving from another
    /// workflow still keeps the pair, with a tag the harness skips.
    var savedPairsAreScoredNote: String? {
        guard let finished, !finished.workflow.isCleanedText else { return nil }
        return "The eval tool only scores Cleaned Text pairs. This one is kept, and skipped there."
    }

    func start() {
        runTask?.cancel()
        runTask = Task { await run() }
    }

    func run() async {
        guard let workflow = selectedWorkflow, !trimmedInput.isEmpty else { return }
        let text = trimmedInput
        runCounter += 1
        let ticket = runCounter
        phase = .running
        notice = nil
        do {
            let outcome = try await runner(text, workflow)
            guard ticket == runCounter else { return }
            editedResult = outcome.output
            phase = .finished(Finished(input: text, workflow: workflow, outcome: outcome))
        } catch is CancellationError {
            guard ticket == runCounter else { return }
            phase = .idle
        } catch {
            guard ticket == runCounter else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    func cancel() {
        runTask?.cancel()
        runCounter += 1
        if phase == .running { phase = .idle }
    }

    /// Keeps the pair with the result as it stands in the editor: the workflow's own output when it was not
    /// touched ("keep as is"), the edited text otherwise.
    func saveExample() {
        guard let finished else { return }
        let example = PlaygroundExample.make(
            raw: finished.input, output: finished.outcome.output, expected: editedResult,
            workflowName: finished.workflow.name, template: finished.workflow.template)
        do {
            try store.append(example)
            notice = example.wasEdited ? "Saved your edited result." : "Saved as it is."
            reload()
        } catch PlaygroundExampleStore.StoreError.emptyText {
            notice = "Nothing to save: the result is empty."
        } catch {
            notice = "Could not save: \(error.localizedDescription)"
        }
    }

    func delete(_ example: PlaygroundExample) {
        do {
            try store.delete(id: example.id)
            notice = "Deleted."
        } catch {
            notice = "Could not delete: \(error.localizedDescription)"
        }
        reload()
    }

    func export(to destination: URL) {
        do {
            let count = try store.export(to: destination)
            notice = "Exported \(count) \(count == 1 ? "pair" : "pairs")."
        } catch {
            notice = "Could not export: \(error.localizedDescription)"
        }
    }

    func reload() {
        let loaded = store.load()
        examples = loaded.examples
        unreadableLines = loaded.unreadableLines
    }

    private var trimmedInput: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }
}
