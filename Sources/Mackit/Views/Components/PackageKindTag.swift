import SwiftUI

/// The FORMULA / CASK tag that sits beside a package's name — in the
/// installed list, the package detail header and the install section's
/// search results alike.
struct PackageKindTag: View {
    let kind: HomebrewPackage.Kind

    var body: some View {
        Text(verbatim: kind.tagTitle)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(kind == .formula ? .orange : .blue)
    }
}
