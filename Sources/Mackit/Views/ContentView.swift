import SwiftUI

/// Main container: sidebar + detail area.
struct ContentView: View {
    @Environment(AppViewModel.self) private var vm
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// The card's rounded shape: shared by both background and content clipping,
    /// avoiding a separate radius in each place.
    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
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
            // lands in the white area.
            //
            // Modifier order is critical: background must come before padding.
            // Written the other way around (.padding().background()), padding
            // becomes the card's inner padding — the content shrinks in, while
            // the card itself still hugs the sidebar and the window's right edge.
            VStack(spacing: 0) {
                // The settings and hardware pages have their own headers; the
                // main toolbar's scan / clean actions are unrelated to them, so
                // it is hidden entirely, leaving only the page content.
                if !vm.showsSettings && !vm.showsHardware {
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
            .padding([.leading, .trailing, .bottom], 12)
            // The window top has a non-negligible title bar safe area (about
            // 38pt, where the system traffic lights and the sidebar toggle
            // float). A negative padding cancels it out, so the top gap matches
            // the other three sides.
            .padding(.top, -26)
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
        .background {
            // Make the transition between toolbar and content closer to system apps.
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var detail: some View {
        // When the sidebar's hardware detection / settings row is selected, the
        // detail area switches entirely to the corresponding embedded page
        // (within the same window, not a separate window); clicking back or any
        // category row returns to the cleanable items content.
        if vm.showsHardware {
            HardwareView()
        } else if vm.showsSettings {
            SettingsView()
        } else {
            switch vm.cleanPhase {
            case .done:
                CleanResultView()
            case .cleaning:
                ItemListView()
            case .confirming:
                // The confirmation panel is shown as a sheet, keeping the list
                // behind it.
                ItemListView()
            case .idle:
                if vm.phase == .scanning {
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
                } else if vm.items.isEmpty {
                    WelcomeView()
                } else {
                    ItemListView()
                }
            }
        }
    }
}
