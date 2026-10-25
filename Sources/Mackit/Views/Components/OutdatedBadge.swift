import SwiftUI

/// The "upgrade available" badge beside an outdated package's name — in the
/// installed list and the package detail header alike.
struct OutdatedBadge: View {
    var body: some View {
        Text(verbatim: L10n.tr("homebrew.package.outdated"))
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.green)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.green.opacity(0.15))
            )
    }
}
