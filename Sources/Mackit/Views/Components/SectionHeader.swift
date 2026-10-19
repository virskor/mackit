import SwiftUI

/// Section header: small semibold secondary-colored text, with an optional trailing note on the right (count, size, etc.).
struct SectionHeader: View {
    let title: String
    var symbol: String?
    var trailing: String?

    var body: some View {
        HStack {
            label
            Spacer()
            if let trailing {
                Text(verbatim: trailing)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private var label: some View {
        // title / trailing are both passed in by the caller, already localized results
        let text = Text(verbatim: title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
        if let symbol {
            Label { text } icon: { Image(systemName: symbol) }
        } else {
            text
        }
    }
}
