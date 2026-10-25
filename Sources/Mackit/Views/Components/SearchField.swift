import SwiftUI

/// The in-card search field: magnifying glass, plain text field, and a
/// trailing clear button that yields to a spinner while a query runs.
///
/// One component in place of the three hand-built copies this app had
/// (the content toolbar and both Homebrew panes), because none of them
/// wore Liquid Glass: a `TextField` in a content area picks up neither
/// the system's glass nor its toolbar chrome — the system reserves
/// Liquid Glass for its own toolbars and sidebars — so each copy painted
/// its own flat fill and stayed flat on macOS 26 while the buttons
/// around it went glass. The plate now rides `GlassSurface` like every
/// other control in the app: glass on macOS 26+, the flat fill the
/// fields always had below.
///
/// A capsule on both paths rather than the 6–7pt rounds the fields used
/// to draw: the system's search fields have been stadiums since Big Sur,
/// and the capsule matches the chrome the field sits among — the scan
/// button's glass plate and the safe-only switch's pill in the toolbar.
struct SearchField: View {
    /// Which chrome the field wears; the toolbar's field is roomier than
    /// the panes' list filters.
    enum Variant {
        /// The content toolbar's field: 13pt text in taller chrome, over
        /// the fill the safe-only switch beside it matches.
        case toolbar
        /// The Homebrew panes' list filters: 12pt text, tighter chrome.
        case list

        var fontSize: CGFloat {
            switch self {
            case .toolbar: 13
            case .list: 12
            }
        }

        var spacing: CGFloat {
            switch self {
            case .toolbar: 4
            case .list: 6
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .toolbar: 9
            case .list: 8
            }
        }

        var verticalPadding: CGFloat {
            switch self {
            case .toolbar: 6
            case .list: 6
            }
        }

        /// The plate below macOS 26, per variant, so the toolbar field
        /// keeps matching the safe-only switch's fill.
        var fallbackFill: AnyShapeStyle {
            switch self {
            case .toolbar: AnyShapeStyle(.quaternary.opacity(0.45))
            case .list: AnyShapeStyle(Color.primary.opacity(0.06))
            }
        }
    }

    @Binding var text: String
    /// The placeholder, already localized by the caller.
    let placeholder: String
    var variant: Variant = .list
    /// Whether a clear button follows non-empty text. The package list's
    /// filter omits it: typing over what's there is that field's idiom.
    var showsClearButton = true
    /// Replaces the clear button with a working spinner — the one state
    /// where a field re-running its query must say "working on it"
    /// without moving the rows below it.
    var isSearching = false
    /// The clear button's tooltip, already localized by the caller.
    var clearButtonHelp: String?

    var body: some View {
        GlassSurface(
            style: .regular,
            interactive: true,
            outline: .capsule,
            fallback: .fill(variant.fallbackFill)
        ) {
            HStack(spacing: variant.spacing) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                TextField(text: $text) {
                    Text(verbatim: placeholder)
                        .font(.system(size: variant.fontSize))
                }
                .textFieldStyle(.plain)
                .font(.system(size: variant.fontSize))

                trailing
            }
            .padding(.horizontal, variant.horizontalPadding)
            .padding(.vertical, variant.verticalPadding)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if isSearching {
            ProgressView()
                .controlSize(.small)
                .frame(width: 14, height: 14)
        } else if showsClearButton && !text.isEmpty {
            if let clearButtonHelp {
                clearButton.help(clearButtonHelp)
            } else {
                clearButton
            }
        }
    }

    private var clearButton: some View {
        Button {
            text = ""
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }
}
