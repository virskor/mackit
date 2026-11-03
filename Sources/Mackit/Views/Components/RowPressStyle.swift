import SwiftUI

/// Press feedback for list rows: a soft fill that fades in while held.
/// `.plain` rows give no press response on macOS, which makes the list feel
/// dead; a scale-down would be wrong here — rows are wide, and scaling a wide
/// row looks broken.
struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed ? Theme.Palette.surfaceHover : .clear,
                in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
            )
            .animation(.easeOut(duration: Theme.Motion.stateChange), value: configuration.isPressed)
    }
}
