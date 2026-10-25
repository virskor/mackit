import SwiftUI

/// Main container: sidebar + detail area.
struct ContentView: View {
    @Environment(AppViewModel.self) private var vm
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// The card's rounded shape: shared by both background and content clipping,
    /// avoiding a separate radius in each place. A full-bleed page gets a plain
    /// rectangle — with no inset around it, a rounded corner would bite into
    /// the page's own chrome at the window's corners.
    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: isFullBleed ? 0 : 10, style: .continuous)
    }

    /// Whether the detail area runs edge to edge instead of as an inset card.
    ///
    /// The disk analysis page is a Finder-style tool layout: its own title bar,
    /// toolbar and two columns want the whole detail area, and a card floating
    /// 12pt off the window edges would fight it. The clean result view swaps in
    /// over whichever page was showing when a clean finishes, so it keeps the
    /// card even if the clean was started from the disk analysis page.
    private var isFullBleed: Bool {
        vm.showsDiskAnalysis && vm.cleanPhase != .done
    }

    /// The gap between the card and the window edges / sidebar. Full-bleed
    /// pages drop it to zero. The negative top inset is unconditional: the
    /// window top has a non-negligible title bar safe area (about 38pt, where
    /// the system traffic lights and the sidebar toggle float), and it cancels
    /// it out so the top gap matches the other three sides in both modes.
    private var cardInsets: EdgeInsets {
        let inset: CGFloat = isFullBleed ? 0 : 12
        return EdgeInsets(top: -26, leading: inset, bottom: inset, trailing: inset)
    }

    var body: some View {
        @Bindable var vm = vm

        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            // Only the right content area is rounded into a card: gaps are left
            // on all sides to the window edge and sidebar, while the sidebar
            // stays flush. The toolbar, list, welcome page, scan progress and
            // clean result all live in this card, so the top control bar also
            // lands in the white area. The one exception is the disk analysis
            // page (see `isFullBleed`): it draws a Finder-style layout that
            // wants the full area, so it drops the inset entirely.
            //
            // Modifier order is critical: background must come before padding.
            // Written the other way around (.padding().background()), padding
            // becomes the card's inner padding — the content shrinks in, while
            // the card itself still hugs the sidebar and the window's right edge.
            VStack(spacing: 0) {
                // The settings, hardware, general cleanup, disk analysis and
                // homebrew pages have their own headers; the main toolbar's
                // scan / clean actions are unrelated to them, so it is hidden
                // entirely, leaving only the page content.
                if !vm.showsSettings && !vm.showsHardware && !vm.showsGeneralCleanup && !vm.showsDiskAnalysis && !vm.showsHomebrew {
                    ContentToolbarRow()
                    Divider()
                }
                detail
            }
            .background(.background, in: cardShape)
            // The card content must be clipped back to the card shape: behind
            // the list is an NSTableView, which paints its own opaque background
            // filling the card's lower half, turning the two bottom corners
            // into right angles (the top only has the toolbar, which has no
            // such background, so the corners still look rounded there).
            .clipShape(cardShape)
            .padding(cardInsets)
            .navigationSplitViewColumnWidth(min: 520, ideal: 760)
        }
        .frame(minWidth: 780, minHeight: 480)
        // The confirmation panel hangs off ContentView, at the same level as
        // the toolbar's clean button. Driven directly by cleanPhase rather than
        // @State + onChange: the latter doesn't trigger on "click again after
        // cancel" because the value didn't change, and the panel stops popping up.
        .sheet(isPresented: Binding(
            get: { vm.cleanPhase == .confirming },
            set: { if !$0 { vm.cancelConfirmation() } }
        )) {
            CleanConfirmationView()
                .environment(vm)
        }
        // Operation hints float at the bottom of the window as a floating
        // Toast, not taking up content layout; they auto-dismiss after a few
        // seconds, or can be dismissed immediately by tapping the close button.
        .overlay(alignment: .bottom) {
            if let banner = vm.banner {
                ToastView(banner: banner) { vm.dismissToast() }
                    .padding(.bottom, 28)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: vm.banner?.id)
        // This backdrop sits behind the sidebar column as well as the detail
        // card, so on macOS 26+ it would flatten the sidebar's Liquid Glass:
        // it is painted only below 26, where the window backdrop is the plain
        // window background color and there is no glass to preserve yet.
        .legacyBackdrop {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var detail: some View {
        // A clean owns the detail area, on both features. It used to live in
        // the else-branch below, which meant the general module — whose rows
        // say nothing about progress — swallowed it entirely: clicking clean
        // there ran the clean with no progress overlay and no result summary,
        // and the only feedback was a toast that is easy to miss. Progress
        // and result belong to the action the user just took, not to which
        // page they were browsing.
        switch vm.cleanPhase {
        case .cleaning:
            // The overlay sits on top of whichever page was showing, so the
            // list behind stays visible — the same composition the developer
            // module always had.
            page
                .overlay(alignment: .bottom) { CleanProgressView() }
        case .done:
            CleanResultView()
        case .confirming, .idle:
            // Confirmation is a sheet over the current page; nothing to swap.
            page
        }
    }

    /// The page the sidebar selects, ignoring any clean in flight.
    @ViewBuilder
    private var page: some View {
        // When the sidebar's hardware detection / settings / general cleanup /
        // disk analysis / homebrew row is selected, the detail area switches
        // entirely to the corresponding embedded page (within the same window,
        // not a separate window); clicking back or any category row returns to
        // the cleanable items content.
        if vm.showsHardware {
            HardwareView()
        } else if vm.showsSettings {
            SettingsView()
        } else if vm.showsGeneralCleanup {
            GeneralCleanupView()
        } else if vm.showsDiskAnalysis {
            DiskAnalysisView()
        } else if vm.showsHomebrew {
            HomebrewView()
        } else {
            switch vm.phase {
            case .scanning:
                if vm.items.isEmpty {
                    ScanProgressView()
                } else {
                    // When results already exist, display while scanning:
                    // entries keep growing in the list and the size keeps
                    // accumulating, making it clearer that things are
                    // "not stuck" than waiting idle on a full-screen
                    // progress ring.
                    ItemListView()
                }
            case .idle, .done:
                if vm.items.isEmpty {
                    WelcomeView()
                } else {
                    ItemListView()
                }
            }
        }
    }
}
