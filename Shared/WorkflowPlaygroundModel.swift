import FormatterCore
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
    /// The provider and model the workflow itself is set to, or nil when none is usable.
    var defaultChoice: PlaygroundModelChoice?

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
    /// Cleaned Text only: the model's own text when a check rejected it.
    var rejectedText: String?
    /// Set when no model ran because dictation would not run it either (short take, snippet only, AI not set
    /// up); `output` is then the transcript dictation would paste.
    var skippedReason: String?
}

/// The state behind the Playground: type or paste a sample, run a workflow, see input and result side by side,
/// and save the pair as an example. The model call itself comes in as `runner`.
@MainActor
final class WorkflowPlaygroundModel: ObservableObject {
    /// `choice` is the provider and model picked for this run; the runner uses it for this run only.
    typealias Runner = @MainActor (_ text: String, _ workflow: PlaygroundWorkflow, _ choice: PlaygroundModelChoice?) async throws -> PlaygroundOutcome

    struct Finished: Equatable {
        /// The text and workflow that were run, which a saved pair keeps even if the box changes afterwards.
        let input: String
        let workflow: PlaygroundWorkflow
        /// The provider and model the run used.
        let choice: PlaygroundModelChoice?
        let outcome: PlaygroundOutcome
    }

    enum Phase: Equatable {
        case idle
        case running
        case finished(Finished)
        case failed(String)
    }

    @Published var workflows: [PlaygroundWorkflow]
    @Published var selectedWorkflowID: UUID? {
        // A model picked for one workflow does not carry over to another.
        didSet { if oldValue != selectedWorkflowID { pickedChoiceID = nil } }
    }
    /// Every model the user can run now (the workflow's own is added in `menuChoices`).
    @Published var modelChoices: [PlaygroundModelChoice]
    @Published private var pickedChoiceID: String?
    @Published var input = ""
    @Published private(set) var phase: Phase = .idle
    /// The result as the speaker wants it to read; starts as the workflow's own output.
    @Published var editedResult = ""
    @Published private(set) var examples: [PlaygroundExample] = []
    @Published private(set) var unreadableLines = 0
    /// Why the examples file could not be read, or nil. While it is set, nothing is written to the file.
    @Published private(set) var loadError: String?
    /// A short line after a save, delete or export, or the reason one failed.
    @Published private(set) var notice: String?

    private let runner: Runner
    private let store: PlaygroundExampleStore
    private var runTask: Task<Void, Never>?
    private var runCounter = 0

    init(
        workflows: [PlaygroundWorkflow], modelChoices: [PlaygroundModelChoice] = [], store: PlaygroundExampleStore,
        runner: @escaping Runner
    ) {
        self.workflows = workflows
        self.modelChoices = modelChoices
        self.store = store
        self.runner = runner
        selectedWorkflowID = workflows.first?.id
        reload()
    }

    var selectedWorkflow: PlaygroundWorkflow? { workflows.first { $0.id == selectedWorkflowID } }

    /// The rows of the model menu: the workflow's own provider and model first, then the rest.
    var menuChoices: [PlaygroundModelChoice] {
        PlaygroundModelOptions.merged(modelChoices, own: selectedWorkflow?.defaultChoice)
    }

    /// What the next run uses: the one picked here, else the workflow's own.
    var selectedChoice: PlaygroundModelChoice? {
        menuChoices.first { $0.id == pickedChoiceID } ?? selectedWorkflow?.defaultChoice
    }

    func pick(_ choice: PlaygroundModelChoice) {
        pickedChoiceID = choice.id
    }

    var canRun: Bool {
        selectedWorkflow != nil && !trimmedInput.isEmpty && phase != .running
    }

    /// Where the run is for the symbol effects: a fallback to the plain transcript is the failure-style
    /// moment, a skipped run (no model ran) is neither a finish nor a failure.
    var motionPhase: MotionPhase {
        switch phase {
        case .idle: return .idle
        case .running: return .running
        case .failed: return .failed
        case .finished(let finished):
            if finished.outcome.skippedReason != nil { return .idle }
            return finished.outcome.fallbackReason != nil ? .failed : .finished
        }
    }

    var finished: Finished? {
        if case .finished(let value) = phase { return value }
        return nil
    }

    /// True when the sample box no longer holds the text the result below is for.
    var resultIsStale: Bool {
        guard let finished else { return false }
        return finished.input != trimmedInput
    }

    /// True once the speaker has changed the result away from what the workflow wrote.
    var resultWasEdited: Bool {
        guard let finished else { return false }
        return editedResult != finished.outcome.output
    }

    /// The sentence for a Cleaned Text run that pasted the plain transcript, or nil.
    var fallbackSentence: String? {
        guard let finished, finished.workflow.isCleanedText, let code = finished.outcome.fallbackReason else { return nil }
        return PlaygroundFallbackText.fullSentence(forCode: code)
    }

    /// The model's rejected text against the take it was given, word by word, or nil when nothing was rejected.
    var rejectedDiff: [WordDiff.Segment]? {
        guard let finished, finished.workflow.isCleanedText, finished.outcome.fallbackReason != nil,
            let rejected = finished.outcome.rejectedText, !rejected.isEmpty
        else { return nil }
        let given = FillerCleaner.clean(finished.input, context: .plain)
        return WordDiff.segments(from: given, to: rejected)
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
        let choice = selectedChoice
        runCounter += 1
        let ticket = runCounter
        phase = .running
        notice = nil
        do {
            let outcome = try await runner(text, workflow, choice)
            guard ticket == runCounter else { return }
            editedResult = outcome.output
            phase = .finished(Finished(input: text, workflow: workflow, choice: choice, outcome: outcome))
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
            workflowName: finished.workflow.name, template: finished.workflow.template,
            model: finished.choice?.modelName)
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
            try store.delete(example)
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
        do {
            let loaded = try store.load()
            examples = loaded.examples
            unreadableLines = loaded.unreadableLines
            loadError = nil
        } catch {
            examples = []
            unreadableLines = 0
            loadError = "Could not read the saved examples: \(error.localizedDescription) Nothing will be written until that is fixed."
        }
    }

    private var trimmedInput: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }
}
