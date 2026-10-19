import SwiftUI

/// The "Save a correction" row in the Auto Learn section: how many identical corrections it takes
/// before Pnoe adds the pair to the dictionary. The info button is passed in so the row has no
/// dependency on the app's design system and can be rendered on its own.
struct AutoLearnRepeatThresholdRow<InfoButton: View>: View {
    @Binding var selection: AutoLearnRepeatThreshold
    @ViewBuilder var infoButton: InfoButton

    var body: some View {
        LabeledContent {
            Picker("", selection: $selection) {
                ForEach(AutoLearnRepeatThreshold.allCases) { threshold in
                    Text(threshold.title).tag(threshold)
                }
            }
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Text("Save a correction")
                infoButton
            }
        }
    }
}
