import SwiftUI

/// The aggregate status of an app's startup items: all on, some on, or
/// all off.
///
/// A pill rather than bare colored text: the three states differ by
/// color *and* by word, so the status survives a colorblind user and a
/// grayscale screenshot alike. The tint rides the same green / orange /
/// gray ramp the rest of the app uses for on / partial / off states.
struct StatusPill: View {
    enum Status: Equatable, Sendable {
        case allEnabled
        case partial
        case allDisabled
    }

    let status: Status

    private var text: String {
        switch status {
        case .allEnabled: return L10n.tr("loginItems.status.allEnabled")
        case .partial: return L10n.tr("loginItems.status.partial")
        case .allDisabled: return L10n.tr("loginItems.status.allDisabled")
        }
    }

    private var tint: Color {
        switch status {
        case .allEnabled: return .green
        case .partial: return .orange
        case .allDisabled: return .secondary
        }
    }

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(tint.opacity(0.14))
            )
            .fixedSize()
    }
}
