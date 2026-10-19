import SwiftUI

/// Circular progress indicator: base ring + progress arc + center content.
///
/// The scan page and the cleanup overlay use the same visual language, differing only
/// in diameter, line width, and center text, so the ring itself is extracted here and
/// the center content is provided by the caller with a ViewBuilder.
struct ProgressRing<Center: View>: View {
    /// 0…1; progress is clamped to this range.
    var progress: Double
    var diameter: CGFloat
    var lineWidth: CGFloat
    var tint: Color = .accentColor
    @ViewBuilder var center: Center

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.15), lineWidth: lineWidth)
                .frame(width: diameter, height: diameter)

            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .frame(width: diameter, height: diameter)
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.25), value: progress)

            center
        }
    }
}
