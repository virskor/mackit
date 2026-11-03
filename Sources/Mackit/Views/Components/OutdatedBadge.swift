import SwiftUI

/// The "upgrade available" badge beside an outdated package's name — in the
/// installed list and the package detail header alike.
struct OutdatedBadge: View {
    var body: some View {
        Text(verbatim: L10n.tr("homebrew.package.outdated"))
            .font(Theme.Typography.microMedium)
            .foregroundStyle(Theme.Palette.success)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous)
                    .fill(Theme.Palette.success.opacity(Theme.Palette.Tint.badge))
            )
    }
}
