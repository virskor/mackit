import SwiftUI

/// The success mark on the results page: a green circle whose checkmark draws
/// itself in, while the badge pops up from small.
///
/// A static checkmark says "done" but feels like paperwork; the draw-in is
/// the smallest celebration the moment can carry. Both motions are one-shot
/// on appear — a repeating bounce here would get annoying on every clean.
struct SuccessMark: View {
    var diameter: CGFloat = 64

    /// Whether the checkmark has finished drawing; drives both motions.
    @State private var drawn = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.green.opacity(0.12))

            checkmark
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(
                    Color.green,
                    style: StrokeStyle(lineWidth: diameter * 0.09, lineCap: .round, lineJoin: .round)
                )
                .animation(.easeOut(duration: 0.4).delay(0.12), value: drawn)
        }
        .frame(width: diameter, height: diameter)
        .scaleEffect(drawn ? 1 : 0.6)
        .animation(.spring(response: 0.5, dampingFraction: 0.55), value: drawn)
        .onAppear { drawn = true }
    }

    private var checkmark: Path {
        Path { path in
            path.move(to: CGPoint(x: diameter * 0.27, y: diameter * 0.52))
            path.addLine(to: CGPoint(x: diameter * 0.44, y: diameter * 0.69))
            path.addLine(to: CGPoint(x: diameter * 0.74, y: diameter * 0.34))
        }
    }
}
