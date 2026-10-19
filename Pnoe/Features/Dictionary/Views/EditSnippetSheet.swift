import SwiftData
import SwiftUI

/// Adds a snippet, or edits an existing one when `snippet` is set.
struct EditSnippetSheet: View {
    let snippet: Snippet?
    let existing: [Snippet]
    let modelContext: ModelContext

    @Environment(\.dismiss) private var dismiss

    @State private var trigger: String
    @State private var expansion: String
    @State private var showAlert = false
    @State private var alertMessage = ""

    init(snippet: Snippet?, existing: [Snippet], modelContext: ModelContext) {
        self.snippet = snippet
        self.existing = existing
        self.modelContext = modelContext
        _trigger = State(initialValue: snippet?.trigger ?? "")
        _expansion = State(initialValue: snippet?.expansion ?? "")
    }

    private var canSave: Bool {
        !SnippetTrigger.normalized(trigger).isEmpty
            && !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .overlay(Divider().opacity(0.5), alignment: .bottom)
            ScrollView {
                VStack(spacing: 16) {
                    Text(
                        "Say the trigger phrase while dictating and Pnoe inserts the text below, exactly as written."
                    )
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Trigger phrase").font(.headline)
                        TextField("For example: my email", text: $trigger)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Inserted text").font(.headline)
                        TextEditor(text: $expansion)
                            .font(.body)
                            .frame(height: 140)
                            .padding(8)
                            .background(Color(.textBackgroundColor))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(AppTheme.Border.control, lineWidth: 1)
                            )
                    }
                }
                .padding()
            }
        }
        .frame(width: 460, height: 460)
        .alert("Snippet", isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private var header: some View {
        HStack {
            Button("Cancel", role: .cancel) { dismiss() }
                .buttonStyle(.borderless)
                .keyboardShortcut(.escape, modifiers: [])

            Spacer()

            Text(snippet == nil ? "Add Snippet" : "Edit Snippet")
                .font(.headline)

            Spacer()

            Button("Save") { save() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canSave)
        }
        .focusEffectDisabled()
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(AppCardBackground(isSelected: false, cornerRadius: 16))
    }

    private func save() {
        let error: String?
        if let snippet {
            error = SnippetService.update(
                snippet, trigger: trigger, expansion: expansion, existing: existing, context: modelContext)
        } else {
            error = SnippetService.add(
                trigger: trigger, expansion: expansion, existing: existing, context: modelContext)
        }
        if let error {
            alertMessage = error
            showAlert = true
            return
        }
        dismiss()
    }
}
