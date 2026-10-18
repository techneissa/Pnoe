import SwiftUI

struct AboutView: View {
    static let creditsURL = URL(string: "https://github.com/techneissa/Pnoe/blob/main/CREDITS.md")!

    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    private let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                AppIconView()
                    .padding(.top, 24)

                Text(verbatim: "Pnoe")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))

                Text("Version \(appVersion) (\(appBuild))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Text("Based on VoiceInk by Prakash Joshi Pax, under GPL-3.0.")
                    .font(.callout)
                    .multilineTextAlignment(.center)

                Link("Credits", destination: Self.creditsURL)
                    .font(.callout)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
