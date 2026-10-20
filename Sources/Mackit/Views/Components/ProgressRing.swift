import SwiftUI

/// Circular progress indicator: track + gradient arc + optional scanning sweep.
///
/// The scan page and the cleanup overlay share the ring; the sweep — a short
/// arc spinning around the track — only runs while a scan is active. A
/// filesystem walk has long stretches where the fraction barely moves, and a
/// static ring reads as "stalled" there; the sweep says "still working"
/// without faking progress. The cleanup overlay passes `isActive: false`:
/// its arc advances steadily on its own.
struct ProgressRing<Center: View>: View {
    /// 0…1; progress is clamped to this range.
    var progress: Double
    var diameter: CGFloat
    var lineWidth: CGFloat
    var isActive: Bool = false
    @ViewBuilder var center: Center

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
                .frame(width: diameter, height: diameter)

            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(
                    // Angular rather than linear: a ring's gradient should
                    // wrap around the track, not cut across it.
                    AngularGradient(
                        colors: [BrandPalette.amber, BrandPalette.deepOrange, BrandPalette.amber],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .frame(width: diameter, height: diameter)
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.25), value: progress)

            if isActive {
                SweepArc(diameter: diameter, lineWidth: lineWidth)
            }

            center
        }
    }
}

/// The spinning sweep drawn over the ring while a scan runs.
private struct SweepArc: View {
    var diameter: CGFloat
    var lineWidth: CGFloat

    var body: some View {
        Circle()
            .trim(from: 0.68, to: 0.94)
            .stroke(
                BrandPalette.lemon.opacity(0.55),
                style: StrokeStyle(lineWidth: lineWidth * 0.55, lineCap: .round)
            )
            .frame(width: diameter, height: diameter)
            // One turn every 1.5s: fast enough to read as "working",
            // slow enough not to flicker.
            .spinning(period: 1.5)
    }
}
