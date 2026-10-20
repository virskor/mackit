import SwiftUI

/// Large primary action button: borderedProminent + large + default keyboard shortcut.
///
/// The confirmation panel's primary action. The results page and the general
/// module's call to action use `BrandCTAButton` instead, which carries the
/// brand green; this one keeps the window accent, because the confirmation's
/// primary action turns red for the destructive cases (caution items, app
/// uninstall).
struct ProminentActionButton: View {
    let title: String
    var tint: Color = .accentColor
    var minWidth: CGFloat = 76
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            // title is passed in by the caller, already a localized result
            Text(verbatim: title)
                .frame(minWidth: minWidth)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
    }
}
