import AppKit
import SwiftUI

/// The Workflows Playground: pick a workflow, type or paste a sample (or click in the box and use the normal
/// recording shortcut), run it, and see the input and the result side by side with the time taken. A pair
/// can be saved as an example, kept as it is or edited into what it should have been. It holds no app
/// types, so a test can render it offscreen.
struct WorkflowPlaygroundView: View {
    @ObservedObject var model: WorkflowPlaygroundModel
    let onDismiss: () -> Void

    @State private var isEditingResult = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sampleSection
                    examplesSection
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onExitCommand(perform: onDismiss)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("Try a Workflow")
                .font(.headline)
                .fontWeight(.semibold)
            InfoTip(
                "Run a workflow on a sample and compare the result with your text. Nothing is pasted anywhere, and saved examples stay on this Mac.",
                accessibilityLabel: "About Try a Workflow")
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(6)
                    .background(Color.secondary.opacity(0.10))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Close")
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    // MARK: - Sample and result

    private var sampleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.workflows.isEmpty {
                Text("No workflow uses AI yet. Add one from a template, such as Cleaned Text, to try it here.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            } else {
                HStack(spacing: 8) {
                    Text("Workflow")
                    Picker("Workflow", selection: $model.selectedWorkflowID) {
                        ForEach(model.workflows) { workflow in
                            Text(workflow.name).tag(Optional(workflow.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                }
            }

            HStack(alignment: .top, spacing: 12) {
                column(title: "Sample") {
                    textBox(
                        text: $model.input, minHeight: 110,
                        placeholder: "Type or paste a sample, or click here and dictate")
                        .accessibilityLabel("Sample text")
                }
                column(title: "Result") {
                    resultBox
                }
            }

            HStack(spacing: 10) {
                Button {
                    model.start()
                } label: {
                    Text("Run")
                        .frame(minWidth: 52)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!model.canRun)

                if model.phase == .running {
                    ProgressView().controlSize(.small)
                    Button("Cancel", action: model.cancel)
                        .buttonStyle(.link)
                }
                if let finished = model.finished {
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                        Text(
                            finished.outcome.skippedReason == nil
                                ? "\(finished.workflow.name), \(Self.seconds(finished.outcome.duration))"
                                : "\(finished.workflow.name), no model ran")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                Spacer()
            }

            Text("To dictate a sample, click in the sample box and use your recording shortcut. Pnoe pastes the take into the box.")
                .font(.caption)
                .foregroundColor(.secondary)

            verdict
        }
    }

    @ViewBuilder
    private var resultBox: some View {
        switch model.phase {
        case .finished:
            if isEditingResult {
                textBox(text: $model.editedResult, minHeight: 110, placeholder: "")
                    .accessibilityLabel("Result, editable")
            } else {
                readOnlyBox(model.editedResult, minHeight: 110)
            }
        case .running:
            readOnlyBox("Running…", minHeight: 110, dimmed: true)
        case .failed(let message):
            readOnlyBox(message, minHeight: 110, color: .red)
        case .idle:
            readOnlyBox("The result appears here.", minHeight: 110, dimmed: true)
        }
    }

    /// The line under the boxes: passed, fell back (with the refused text), skipped, or stale.
    @ViewBuilder
    private var verdict: some View {
        if let finished = model.finished {
            VStack(alignment: .leading, spacing: 10) {
                if model.resultIsStale {
                    Label("The sample changed since this run. Run again to see its result.", systemImage: "arrow.clockwise")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                if let skipped = finished.outcome.skippedReason {
                    Label(skipped, systemImage: "forward.end")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let sentence = model.fallbackSentence {
                    Label(sentence, systemImage: "arrow.uturn.backward.circle")
                        .font(.callout)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if finished.workflow.isCleanedText {
                    Label("The result passed Pnoe's checks.", systemImage: "checkmark.circle")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }

                if let segments = model.rejectedDiff {
                    rejectedSection(segments)
                }

                HStack(spacing: 10) {
                    Button(isEditingResult ? "Done editing" : "Edit result") {
                        isEditingResult.toggle()
                    }
                    Button(model.resultWasEdited ? "Save edited result" : "Save as example") {
                        model.saveExample()
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                }

                if let note = model.savedPairsAreScoredNote {
                    Text(note).font(.caption).foregroundColor(.secondary)
                }
            }
        } else if case .failed = model.phase {
            EmptyView()
        }
    }

    /// The model's refused text, greyed, with the words it added underlined in red and the words it dropped
    /// struck through.
    private func rejectedSection(_ segments: [WordDiff.Segment]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What the model wrote")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            Text(Self.attributed(segments))
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor).opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
            Text("Red underlined words are ones the model added; struck-through words are ones it left out.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    static func attributed(_ segments: [WordDiff.Segment]) -> AttributedString {
        var result = AttributedString()
        for (index, segment) in segments.enumerated() {
            var piece = AttributedString((index == 0 ? "" : " ") + segment.word)
            switch segment.kind {
            case .kept:
                piece.foregroundColor = .secondary
            case .added:
                piece.foregroundColor = .red
                piece.underlineStyle = .single
            case .missing:
                piece.foregroundColor = .red
                piece.strikethroughStyle = .single
            }
            result.append(piece)
        }
        return result
    }

    // MARK: - Saved examples

    private var examplesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Saved examples")
                    .font(.system(size: 14, weight: .semibold))
                Text("\(model.examples.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Export…", action: exportExamples)
                    .disabled(model.examples.isEmpty)
            }
            Text("Kept in a file on this Mac and never uploaded. The eval tool can score a model against them.")
                .font(.caption)
                .foregroundColor(.secondary)

            if let notice = model.notice {
                Text(notice).font(.caption).foregroundColor(.accentColor)
            }
            if let loadError = model.loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.unreadableLines > 0 {
                Text("\(model.unreadableLines) unreadable \(model.unreadableLines == 1 ? "line is" : "lines are") left untouched in the file.")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            if model.examples.isEmpty {
                Text("Nothing saved yet.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 8) {
                    ForEach(model.examples, id: \.listID) { example in
                        exampleRow(example)
                    }
                }
            }
        }
    }

    private func exampleRow(_ example: PlaygroundExample) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(example.workflow).font(.system(size: 12, weight: .semibold))
                    if example.wasEdited {
                        Text("edited")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
                Text(example.raw)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                Text(example.expected)
                    .font(.caption)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
            Button {
                model.delete(example)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Delete this example")
            .accessibilityLabel("Delete example")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: - Pieces

    private func column<Content: View>(title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func readOnlyBox(_ text: String, minHeight: CGFloat, dimmed: Bool = false, color: Color? = nil) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(color ?? (dimmed ? .secondary : .primary))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
    }

    private func textBox(text: Binding<String>, minHeight: CGFloat, placeholder: LocalizedStringKey) -> some View {
        TextEditor(text: text)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: minHeight)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15)))
            .overlay(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
    }

    static func seconds(_ duration: TimeInterval) -> String {
        String(format: "%.1f s", duration)
    }

    private func exportExamples() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "pnoe-examples.jsonl"
        panel.canCreateDirectories = true
        panel.title = "Export Saved Examples"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.export(to: url)
    }
}
