import AppKit
import Observation
import SwiftUI

/// Owns the agent's menu bar status item: the icon, the left-click panel
/// popover, and the right-click context menu.
///
/// Why not SwiftUI's `MenuBarExtra`: it cannot tell a left click from a
/// right click — the same window opens for either — and its `.menu` style
/// hosts SwiftUI content into an NSMenu, which cannot render the panel's
/// multi-column layout. The product wants the two gestures to do different
/// things (left click opens the stats panel, right click pops up the native
/// menu), so the status item is owned by AppKit here. This also retires the
/// three places that matched SwiftUI's internal `MenuBarExtraWindow` class
/// name (panel sizing, panel dismissal, visibility checks): those became
/// explicit popover lifecycle methods on this controller.
///
/// `updateLabel` mirrors what the old SwiftUI label did: the VM is observed
/// through an `Observation` tracking loop, and the template stats image is
/// redrawn on every snapshot or display-switch change. The loop re-arms
/// itself after each refresh — Swift fires `onChange` exactly once per
/// tracked read, so a fresh `withObservationTracking` is required every
/// time.
@MainActor
final class TrayStatusController: NSObject, NSPopoverDelegate {
    /// The live controller, for the panel's sizing / dismissal hooks and the
    /// VM's panel-visibility check. Weak: `AppDelegate` holds the strong
    /// reference for the life of the process.
    static weak var current: TrayStatusController?

    private let viewModel: AppViewModel
    private let statusItem: NSStatusItem
    private let panelPopover: NSPopover

    /// When the panel last closed through the popover's own dismissal.
    ///
    /// A transient popover closes on the very mouse-down that lands on the
    /// status item button (it counts as an outside click), and the same
    /// click then runs the button action — which would immediately reopen
    /// the panel the user just dismissed. The button action ignores clicks
    /// that arrive within this window of a close.
    private var lastPanelCloseAt: ContinuousClock.Instant?

    /// The display-switch values last seen by the observation loop. The
    /// four switches also gate the desktop overlay, so `sync()` runs only
    /// when one of them actually changed — snapshot publishes happen every
    /// two seconds and must not count as a settings change.
    private var displaySwitches: DisplaySwitches

    private struct DisplaySwitches: Equatable {
        var cpu: Bool
        var memory: Bool
        var temperature: Bool
        var overlay: Bool
    }

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        // .variableLength rather than a fixed width: the stats image already
        // reserves each group's widest rendering, so the item only has to
        // fit the image. The image is a template, so the system tints it
        // black or white with the menu bar's appearance.
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.panelPopover = NSPopover()
        self.displaySwitches = DisplaySwitches(
            cpu: viewModel.showMenuBarCPU,
            memory: viewModel.showMenuBarMemory,
            temperature: viewModel.showMenuBarTemperature,
            overlay: viewModel.showDesktopStats
        )
        super.init()

        // Both buttons go through one action; the dispatcher below tells
        // them apart by the current event's type.
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusButtonClicked)

        panelPopover.behavior = .transient
        panelPopover.delegate = self
        panelPopover.contentViewController = NSHostingController(
            rootView: MenuBarPanelView().environment(viewModel)
        )

        Self.current = self
        updateLabel()
        observeState()
    }

    // MARK: - Panel (left click)

    /// Whether the panel popover is on screen. The VM reads this to keep
    /// monitoring alive while an open panel is being looked at.
    var isPanelVisible: Bool {
        panelPopover.isShown
    }

    /// Close the panel. The panel's own buttons call this after actions
    /// that change windows, so the popover never lingers over a window that
    /// just came to the front.
    func closePanel() {
        // close() rather than performClose(): behave the same whatever the
        // popover's transient state is; a no-op when already closed.
        panelPopover.close()
    }

    /// Sync the popover's content area to the panel's measured size.
    ///
    /// Called from the panel view's `GeometryReader` on every size change.
    /// An NSPopover draws from `contentSize` and does not track SwiftUI's
    /// fitting size while it is open: when the content height changes (an
    /// app quitting removes a row, the monitor switches collapse a
    /// section, a page swap swaps the whole body), the popover would keep
    /// its old height and either leave blank space below the content or
    /// clip it. Sub-half-pixel jitter is skipped so the two-second polling
    /// does not keep resetting the size.
    func panelContentSizeChanged(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let current = panelPopover.contentSize
        guard abs(current.width - size.width) > 0.5 || abs(current.height - size.height) > 0.5 else { return }
        panelPopover.contentSize = size
    }

    private func togglePanel() {
        if panelPopover.isShown {
            panelPopover.close()
            return
        }
        // The click that closed the panel also lands here (see
        // `lastPanelCloseAt`); it must not reopen what it just dismissed.
        if let closedAt = lastPanelCloseAt, ContinuousClock.now - closedAt < .milliseconds(250) {
            return
        }
        guard let button = statusItem.button else { return }
        // Seed the content size from the host's fitting size so the first
        // frame already has the panel's real height; the geometry callback
        // keeps it in sync afterwards. The fallback only matters if the
        // host has not laid out yet, which cannot normally happen before a
        // show — but a wrong-but-visible panel beats a zero-height one.
        let hosted = panelPopover.contentViewController?.preferredContentSize
        panelPopover.contentSize = hosted.map { host in
            host.height > 0 ? host : NSSize(width: 360, height: 420)
        } ?? NSSize(width: 360, height: 420)
        panelPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        lastPanelCloseAt = .now
    }

    // MARK: - Context menu (right click)

    @objc private func statusButtonClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePanel()
        }
    }

    private func showContextMenu() {
        // The panel and a menu at the same time would overlap; the menu is
        // the user's latest gesture.
        if panelPopover.isShown { panelPopover.close() }
        guard let button = statusItem.button else { return }

        let state = TrayMenuState(
            updateEnabled: UpdateController.isEnabled(feedURL: AppBridge.mainAppUpdateFeedURL()),
            showCPU: viewModel.showMenuBarCPU,
            showMemory: viewModel.showMenuBarMemory,
            showTemperature: viewModel.showMenuBarTemperature,
            showOverlay: viewModel.showDesktopStats
        )
        let menu = makeMenu(state: state)
        // Anchored just above the button's top edge (the point is in the
        // button's bottom-left-origin space, so that is `bounds.height + 4`),
        // the menu drops from the menu bar item the way a menu bar utility's
        // context menu does.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    /// Renders `TrayMenuBuilder`'s rows into an NSMenu. The roles ride on
    /// `representedObject`; one target-action selector dispatches them all
    /// (see `performMenuAction`).
    private func makeMenu(state: TrayMenuState) -> NSMenu {
        let menu = NSMenu()
        // A menu presented from a status item resolves its appearance from
        // the context it pops out of — the system status bar — not from the
        // application: over a dark wallpaper macOS auto-darkens the menu
        // bar, and the menu would render dark even while the app (and the
        // system appearance) are light. Pinning the resolved appearance is
        // how the menu follows the appearance setting like every other
        // surface — `NSApp.appearance` already carries the stored choice
        // (see AppAppearance), and resolving through it at popup time also
        // gets "follow the system" right.
        menu.appearance = NSApp.effectiveAppearance
        // Every row decides its own enablement (only Check for Updates can
        // be disabled today); AppKit's automatic validation would re-enable
        // it whenever a target responds within the responder chain.
        menu.autoenablesItems = false
        for entry in TrayMenuBuilder.entries(for: state) {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case let .action(role, title, systemImage, enabled):
                let item = NSMenuItem(title: title, action: #selector(performMenuAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = role
                item.isEnabled = enabled
                // Newer macOS renders menus table-backed and no longer
                // draws `NSMenuItem.image` at all — probing a live build
                // with real selectors, SF Symbols, custom bitmaps and both
                // presentation paths produced no image view whatsoever.
                // The one per-row glyph channel the renderer still honors
                // is the state-image slot, so the icon rides
                // `offStateImage` with the item pinned unchecked; the row
                // then draws exactly like a plain icon row (the state is
                // never toggled here — the toggle rows below keep their
                // default checkmark state images, which is also what makes
                // AppKit reserve the leading column for every row).
                item.state = .off
                item.offStateImage = menuIcon(systemImage)
                // Only two shortcuts exist; they mirror the main window's
                // menu (Settings …, Quit with ⌘Q), whose equivalents the
                // agent's own menu does not get otherwise.
                switch role {
                case .settings: item.keyEquivalent = ","
                case .quit: item.keyEquivalent = "q"
                default: break
                }
                menu.addItem(item)
            case let .toggle(role, title, isOn):
                let item = NSMenuItem(title: title, action: #selector(performMenuAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = role
                item.state = isOn ? .on : .off
                menu.addItem(item)
            }
        }
        return menu
    }

    /// A menu-row glyph as a template symbol image, fed to the items'
    /// state-image slot (the renderer's live glyph channel — see
    /// `makeMenu`). The menu tints the template with the appearance's
    /// label color, the same channel SF Symbols get everywhere in AppKit.
    private func menuIcon(_ systemImage: String?) -> NSImage? {
        guard let systemImage else { return nil }
        return NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
    }

    @objc private func performMenuAction(_ sender: NSMenuItem) {
        guard let role = sender.representedObject as? TrayMenuRole else { return }
        switch role {
        case .openMain:
            viewModel.openMainWindowFromTray()
        case .settings:
            viewModel.openSettingsFromTray()
        case .clean:
            viewModel.cleanFromTray()
        case .appUninstall:
            AppBridge.send(.appUninstall)
        case .homebrew:
            AppBridge.send(.homebrew)
        case .largeFiles:
            AppBridge.send(.largeFiles)
        case .duplicates:
            AppBridge.send(.duplicates)
        case .diskAnalysis:
            AppBridge.send(.diskAnalysis)
        case .loginItems:
            AppBridge.send(.loginItems)
        case .hardware:
            AppBridge.send(.hardware)
        case .toggleCPU:
            viewModel.toggleTrayDisplay(.cpu)
        case .toggleMemory:
            viewModel.toggleTrayDisplay(.memory)
        case .toggleTemperature:
            viewModel.toggleTrayDisplay(.temperature)
        case .toggleOverlay:
            viewModel.toggleTrayDisplay(.desktopOverlay)
        case .checkUpdates:
            AppBridge.send(.checkUpdates)
        case .about:
            // The same standard About panel the main window's app menu
            // shows; the agent activates itself for it, or the panel would
            // open behind other windows of an app that cannot activate on
            // its own.
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        case .quit:
            viewModel.quitFromTray()
        }
    }

    // MARK: - Label image and observation

    /// Redraw the template stats image. Reads the throttled snapshot — the
    /// loop re-renders it on each change, so it must not read live values
    /// (the throttling comment lives on `publishMenuSnapshot`).
    private func updateLabel() {
        statusItem.button?.image = MenuBarStatsImage.image(
            metrics: metrics,
            barHeight: menuBarHeight,
            showIcon: viewModel.showMenuBarLogo
        )
    }

    /// The monitored groups in the menu bar. Same composition the SwiftUI
    /// label used: whichever of the three switches is on, in display order.
    private var metrics: [MenuBarStatsImage.Metric] {
        let stats = viewModel.menuSnapshot.stats
        var result: [MenuBarStatsImage.Metric] = []
        if viewModel.showMenuBarCPU, let usage = stats.cpuUsage {
            result.append(.init(
                value: Formatters.percent(usage),
                label: L10n.tr("menubar.cpu"),
                alternativeValues: percentWidthBasis
            ))
        }
        if viewModel.showMenuBarMemory, stats.memoryTotal > 0 {
            result.append(.init(
                value: Formatters.percent(stats.memoryUsedFraction),
                label: L10n.tr("menubar.memory"),
                alternativeValues: percentWidthBasis
            ))
        }
        if viewModel.showMenuBarTemperature {
            result.append(.init(
                value: stats.temperatureText,
                label: L10n.tr("menubar.temperature"),
                // Both forms the temperature value can take — whole degrees
                // up to three digits, or a thermal-state word on a machine
                // whose sensor table answers nothing; reserving the widest
                // keeps the item from jittering as the value switches form.
                alternativeValues: temperatureTexts
            ))
        }
        return result
    }

    /// The widest string a percentage can ever render to, used to fix the
    /// width of the CPU and memory groups. `Formatters.percent` clamps to
    /// 0–100 with no decimals, so three digits plus the sign is the longest
    /// case there is.
    private let percentWidthBasis = [Formatters.percent(1)]

    /// Every rendering the temperature value can take: whole degrees up to
    /// 110 (the SMC filter's bound), plus the four thermal-state words shown
    /// when no numeric reading is available.
    private var temperatureTexts: [String] {
        ["nominal", "fair", "serious", "critical"]
            .map { L10n.tr("menubar.thermal.\($0)") }
            + [Formatters.degrees(110)]
    }

    /// Menu bar height: the distance between the top of the main screen's
    /// frame and the top of its visible area (regardless of where the Dock
    /// is). Notched machines are about 38pt, unnotched about 22pt — the
    /// two-line font sizes are tiered accordingly.
    private var menuBarHeight: CGFloat {
        guard let screen = NSScreen.main else { return 24 }
        let height = screen.frame.maxY - screen.visibleFrame.maxY
        return height > 0 ? height : 24
    }

    /// Arms one observation round over everything the label depends on.
    ///
    /// `onChange` fires exactly once per tracked read, synchronously during
    /// the mutation — which happens on the main actor (the VM publishes from
    /// `publishMenuSnapshot`), but the AppKit refresh is deferred to a
    /// main-actor task so the redraw never runs inside the VM's mutation.
    private func observeState() {
        withObservationTracking {
            _ = viewModel.menuSnapshot
            _ = viewModel.showMenuBarCPU
            _ = viewModel.showMenuBarMemory
            _ = viewModel.showMenuBarTemperature
            _ = viewModel.showMenuBarLogo
            _ = viewModel.showDesktopStats
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.stateDidChange()
            }
        }
    }

    private func stateDidChange() {
        updateLabel()
        let current = DisplaySwitches(
            cpu: viewModel.showMenuBarCPU,
            memory: viewModel.showMenuBarMemory,
            temperature: viewModel.showMenuBarTemperature,
            overlay: viewModel.showDesktopStats
        )
        if current != displaySwitches {
            displaySwitches = current
            // The same hook the SwiftUI label carried: the master overlay
            // switch and the three monitor switches re-check visibility.
            StatsOverlayController.shared.sync()
        }
        observeState()
    }
}
