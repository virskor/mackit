import SwiftUI

/// A spinner beside a status line — the shared "a query is in flight" row.
///
/// The Homebrew manager's sections each load their own data on first visit
/// (packages, services, diagnostics, configuration), and each showed the
/// same spinner-and-label pair; this is that pair, once. Callers wrap it in
/// whatever framing their column needs.
struct LoadingRow: View {
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)

            Text(verbatim: label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}
