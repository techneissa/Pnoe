import SwiftUI

struct ExpandableSettingsRow<Content: View>: View {
    @Binding private var isExpanded: Bool

    private let isEnabled: Binding<Bool>?
    private let label: LocalizedStringKey
    private let infoMessage: LocalizedStringKey?
    private let infoURL: String?
    private let expandedContentTransition: AnyTransition
    private let content: () -> Content

    @State private var isHandlingToggleChange = false

    init(
        isExpanded: Binding<Bool>,
        isEnabled: Binding<Bool>,
        label: LocalizedStringKey,
        infoMessage: LocalizedStringKey? = nil,
        infoURL: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        _isExpanded = isExpanded
        self.isEnabled = isEnabled
        self.label = label
        self.infoMessage = infoMessage
        self.infoURL = infoURL
        self.expandedContentTransition = .motionPanel(edge: .top)
        self.content = content
    }

    init(
        title: LocalizedStringKey,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        _isExpanded = isExpanded
        self.isEnabled = nil
        self.label = title
        self.infoMessage = nil
        self.infoURL = nil
        self.expandedContentTransition = .motionFade
        self.content = content
    }

    private var rowIsEnabled: Bool {
        isEnabled?.wrappedValue ?? true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                if let isEnabled = isEnabled {
                    Toggle(isOn: isEnabled) {
                        Text(label)
                    }
                } else {
                    Text(label)
                }

                infoTip

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(rowIsEnabled && isExpanded ? 90 : 0))
                    .opacity(rowIsEnabled ? 1 : 0.4)
                    .motion(.disclosure, value: isExpanded)
            }
            .contentShape(Rectangle())
            .motionHover(cornerRadius: 8, outset: 6, suppressed: !rowIsEnabled)
            .onTapGesture {
                guard !isHandlingToggleChange, rowIsEnabled else { return }
                Motion.animate(.disclosure) {
                    isExpanded.toggle()
                }
            }

            if rowIsEnabled && isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    content()
                }
                .padding(.top, 12)
                .padding(.leading, 4)
                .transition(expandedContentTransition)
            }
        }
        .onChange(of: rowIsEnabled) { _, newValue in
            guard isEnabled != nil else { return }
            isHandlingToggleChange = true
            if newValue {
                Motion.animate(.disclosure) {
                    isExpanded = true
                }
            } else {
                Motion.animate(.disclosure) {
                    isExpanded = false
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isHandlingToggleChange = false
            }
        }
    }

    /// Beside the label and toggle rather than inside them, so tapping it never flips the switch.
    @ViewBuilder private var infoTip: some View {
        if let infoMessage = infoMessage {
            if let infoURL = infoURL {
                InfoTip(infoMessage, learnMoreURL: infoURL)
            } else {
                InfoTip(infoMessage)
            }
        }
    }
}
