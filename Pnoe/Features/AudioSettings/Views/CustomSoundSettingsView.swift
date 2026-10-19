import SwiftUI
import UniformTypeIdentifiers

struct CustomSoundSettingsView: View {
    @StateObject private var soundSettings = SoundSettings.shared
    @State private var showingAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""

    private let systemSounds = SystemSounds.available()

    var body: some View {
        Group {
            ForEach(SoundEvent.allCases) { event in
                LabeledContent(event.displayName) {
                    soundControls(for: event)
                }
            }
        }
        .alert(alertTitle, isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    @ViewBuilder
    private func soundControls(for event: SoundEvent) -> some View {
        let choice = soundSettings.choice(for: event)

        HStack(spacing: 8) {
            Picker("Sound", selection: choiceBinding(for: event)) {
                Text("None").tag(SoundChoice.none)

                Section("Pnoe") {
                    ForEach(PnoeSoundSet.allCases) { set in
                        Text(set.displayName).tag(SoundChoice.pnoe(set))
                    }
                }

                if !systemSounds.isEmpty {
                    Section("macOS") {
                        ForEach(systemSounds, id: \.self) { name in
                            Text(SystemSounds.displayName(for: name)).tag(SoundChoice.system(name))
                        }
                    }
                }

                if let fileName = soundSettings.customFilename(for: event) {
                    Section("Custom") {
                        Text(fileName).tag(SoundChoice.custom)
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 116, alignment: .trailing)
            .fixedSize()
            .help("Select sound")

            Button {
                SoundManager.shared.play(event)
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .disabled(choice == .none)
            .help("Test")

            Button {
                selectSound(for: event)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Choose")

            if !soundSettings.isDefault(for: event) {
                Button {
                    soundSettings.resetToDefault(for: event)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Reset")
            }
        }
        .focusEffectDisabled()
    }

    private func choiceBinding(for event: SoundEvent) -> Binding<SoundChoice> {
        Binding(
            get: { soundSettings.choice(for: event) },
            set: { soundSettings.select($0, for: event) }
        )
    }

    private func selectSound(for event: SoundEvent) {
        let panel = NSOpenPanel()
        panel.title = String(format: String(localized: "Choose %@ Sound"), event.rawValue.capitalized)
        panel.message = String(localized: "Select an audio file")
        panel.allowedContentTypes = [
            UTType.audio,
            UTType.mp3,
            UTType.wav,
            UTType.aiff,
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            Task { @MainActor in
                let result = await soundSettings.setCustomSound(url: url, for: event)
                if case .failure(let error) = result {
                    alertTitle = "Invalid Audio File"
                    alertMessage = error.localizedDescription
                    showingAlert = true
                }
            }
        }
    }
}

#Preview {
    CustomSoundSettingsView()
        .frame(width: 400)
        .padding()
}
