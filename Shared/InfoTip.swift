import SwiftUI

/// A reusable info tip component that displays helpful information in a popover
struct InfoTip: View {
    // Content configuration
    var message: LocalizedStringKey
    var learnMoreLink: URL?
    var detail: LocalizedStringKey?

    // Appearance customization
    var iconName: String = "info.circle"
    var iconSize: Image.Scale = .medium
    var iconColor: Color = .primary
    var width: CGFloat = 280
    var accessibilityLabel: LocalizedStringKey = "More information"

    // State
    @State private var isShowingTip: Bool = false

    var body: some View {
        Button {
            isShowingTip.toggle()
        } label: {
            Image(systemName: iconName)
                .imageScale(iconSize)
                .foregroundColor(iconColor)
                .fontWeight(.semibold)
                .padding(5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .popover(isPresented: $isShowingTip) {
            InfoTipContent(message: message, detail: detail, learnMoreLink: learnMoreLink, width: width)
        }
    }
}

struct InfoTipContent: View {
    let message: LocalizedStringKey
    var detail: LocalizedStringKey?
    var learnMoreLink: URL?
    var width: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if learnMoreLink != nil {
                (Text(message)
                    .foregroundColor(.secondary)
                    + Text(" ")
                    + Text("Learn more")
                    .foregroundColor(Color.accentColor))
                    .font(.callout)
            } else {
                Text(message)
                    .font(.callout)
                    .foregroundColor(.secondary)
            }

            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: width, alignment: .leading)
        .padding(14)
        .onTapGesture {
            if let url = learnMoreLink {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

// MARK: - Convenience initializers

extension InfoTip {
    /// Creates an InfoTip with just a message
    init(_ message: LocalizedStringKey) {
        self.message = message
        self.learnMoreLink = nil
    }

    /// Creates an InfoTip with a dynamic string message
    init(_ message: String) {
        self.message = LocalizedStringKey(message)
        self.learnMoreLink = nil
    }

    /// Creates an InfoTip whose button reads `accessibilityLabel` to VoiceOver, with an optional second paragraph
    init(
        _ message: LocalizedStringKey,
        detail: LocalizedStringKey? = nil,
        accessibilityLabel: LocalizedStringKey
    ) {
        self.message = message
        self.learnMoreLink = nil
        self.detail = detail
        self.accessibilityLabel = accessibilityLabel
    }

    /// Creates an InfoTip with a learn more link
    init(_ message: LocalizedStringKey, learnMoreURL: String) {
        self.message = message
        self.learnMoreLink = URL(string: learnMoreURL)
    }

    /// Creates an InfoTip with a dynamic string message and learn more link
    init(_ message: String, learnMoreURL: String) {
        self.message = LocalizedStringKey(message)
        self.learnMoreLink = URL(string: learnMoreURL)
    }
}
