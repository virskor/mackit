import SwiftUI

/// Large primary action button: borderedProminent + large + default keyboard shortcut.
///
/// The confirmation panel and the results page use an identical primary button style,
/// differing only in text and tint.
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
