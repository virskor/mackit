import SwiftUI

/// Press feedback for list rows: a soft fill that fades in while held.
/// `.plain` rows give no press response on macOS, which makes the list feel
/// dead; a scale-down would be wrong here — rows are wide, and scaling a wide
/// row looks broken.
struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed ? Color.primary.opacity(0.06) : .clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
