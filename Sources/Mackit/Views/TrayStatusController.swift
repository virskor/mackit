import AppKit
import Observation
import SwiftUI

/// Owns the agent's menu bar status item: the icon, the left-click panel
/// window, and the right-click context menu.
///
/// Why not SwiftUI's `MenuBarExtra`: it cannot tell a left click from a
/// right click — the same window opens for either — and its `.menu` style
/// hosts SwiftUI content into an NSMenu, which cannot render the panel's
/// multi-column layout. The product wants the two gestures to do different
/// things (left click opens the stats panel, right click pops up the native
/// menu), so the status item is owned by AppKit here.
///
/// Why a borderless `NSPanel` and not an `NSPopover`: a popover's chrome
/// belongs to the system and cannot be overridden. Its material samples the
/// desktop behind the window, so the wallpaper bled through the band above
/// the content — the strip the chevron lives in — and nothing the panel
/// draws (content, layer background, window background) could cover it; the
/// chevron itself is window-drawn, with no view to reach and no material to
/// recolor. A borderless panel draws only what its hosting view draws, so
/// the panel surface — a plain rounded fill (see `MenuBarPanelView`) — is
/// fully opaque. What the popover provided for free is reproduced
/// explicitly here: dismiss on any click outside the app (a global
/// mouse-down monitor), dismiss on the status-item click (the button
/// action), and never take focus (`nonactivatingPanel` +
/// `becomesKeyOnlyIfNeeded`).
///
/// `updateLabel` mirrors what the old SwiftUI label did: the VM is observed
/// through an `Observation` tracking loop, and the template stats image is
/// redrawn on every snapshot or display-switch change. The loop re-arms
/// itself after each refresh — Swift fires `onChange` exactly once per
/// tracked read, so a fresh `withObservationTracking` is required every
/// time.
@MainActor
final class TrayStatusController: NSObject {
    /// The live controller, for the panel's sizing / dismissal hooks and the
    /// VM's panel-visibility check. Weak: `AppDelegate` holds the strong
    /// reference for the life of the process.
    static weak var current: TrayStatusController?

    private let viewModel: AppViewModel
    private let statusItem: NSStatusItem
    private let panel: NSPanel

    /// The panel's last measured content size.
    ///
    /// The SwiftUI panel reports its size from a `GeometryReader` on every
    /// layout; while the panel is hidden the report is only recorded here,
    /// so the next show opens at the right size before the first frame.
    private var lastMeasuredContentSize: CGSize?

    /// The outside-click dismissal monitor (see `startDismissalMonitor`).
    ///
    /// `nonisolated(unsafe)`: the token is only read and written on the main
    /// actor (`start`/`stop` are main-actor methods), and the exemption
    /// exists solely so the nonisolated `deinit` can unregister the monitor.
    nonisolated(unsafe) private var dismissalMonitor: Any?

    /// When the panel last closed.
    ///
    /// A click inside the app never reaches the dismissal monitor, so the
    /// status-item click dismisses the panel through the button action
    /// instead. But the same physical click can arrive both ways — the menu
    /// bar is not this app's — and the action would then reopen the panel
    /// it just saw closed. The button action ignores clicks that arrive
    /// within this window of a close.
    private var lastPanelCloseAt: ContinuousClock.Instant?

    /// The inputs of the last drawn label image, for the redraw dedupe
    /// (see `updateLabel`).
    private var lastLabelInputs: ([MenuBarStatsImage.Metric], CGFloat, Bool)?

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        // .variableLength rather than a fixed width: the stats image already
        // reserves each group's widest rendering, so the item only has to
        // fit the image. The image is a template, so the system tints it
        // black or white with the menu bar's appearance.
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 420),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        configurePanel()

        // Both buttons go through one action; the dispatcher below tells
        // them apart by the current event's type.
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusButtonClicked)

        Self.current = self
        updateLabel()
        observeState()
    }

    deinit {
        if let dismissalMonitor {
            NSEvent.removeMonitor(dismissalMonitor)
        }
    }

    /// The window's own configuration.
    ///
    /// The window draws nothing itself: `backgroundColor` is clear, and the
    /// panel's visible shape — the rounded body — is drawn by the hosting
    /// view in SwiftUI (see `MenuBarPanelView`), with no layer rounding
    /// here. The window shadow derives from the hosting view's alpha, so it
    /// follows the drawn outline.
    private func configurePanel() {
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // A nonactivating panel can still become key when clicked; the
        // panel has no keyboard-driven controls, so taking key would only
        // pull focus out of whatever the user was typing into.
        panel.becomesKeyOnlyIfNeeded = true

        let host = NSHostingController(rootView: MenuBarPanelView().environment(viewModel))
        host.view.wantsLayer = true
        panel.contentViewController = host
    }

    // MARK: - Panel (left click)

    /// Whether the panel is on screen. The VM reads this to keep monitoring
    /// alive while an open panel is being looked at.
    var isPanelVisible: Bool {
        panel.isVisible
    }

    /// Close the panel. The panel's own buttons call this after actions
    /// that change windows, so the panel never lingers over a window that
    /// just came to the front.
    func closePanel() {
        // orderOut rather than close(): the window is reused across shows,
        // and closing it would take the SwiftUI hierarchy down with it.
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        // Collapse the panel's SwiftUI body while hidden (see
        // `MenuBarPanelView`) — the observable flag also stops the
        // all-process ranking from being sampled while nothing can show it.
        viewModel.setPanelPresented(false)
        stopDismissalMonitor()
        lastPanelCloseAt = .now
    }

    /// Sync the panel's size to the view's measured size.
    ///
    /// Called from the panel view's `GeometryReader` on every size change.
    /// The anchor below the status item is computed here (a plain window
    /// has no positioning view), so the frame is set on every change: the
    /// top edge stays put and the height change grows downward, keeping
    /// the panel attached to the icon. Sub-half-pixel jitter is skipped so
    /// the two-second polling does not keep re-setting the frame.
    func panelContentSizeChanged(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        lastMeasuredContentSize = size
        guard panel.isVisible else { return }
        let current = panel.frame.size
        guard abs(current.width - size.width) > 0.5 || abs(current.height - size.height) > 0.5 else { return }
        guard let anchor = panelAnchor() else {
            panel.setContentSize(size)
            return
        }
        // display: false on purpose. Right after the panel is shown, SwiftUI
        // first measures the body at its fitting size and then lays it out
        // at the window's size, so two size reports can arrive in one
        // layout cycle (intrinsic, then final). Painting the intermediate
        // one would flash the panel shorter for a frame; without an
        // immediate display both resizes coalesce and only the final size
        // ever reaches the screen.
        panel.setFrame(panelFrame(anchoredTo: anchor, size: size), display: false)
    }

    private func togglePanel() {
        if panel.isVisible {
            closePanel()
            return
        }
        // The click that closed the panel can also land here (see
        // `lastPanelCloseAt`); it must not reopen what it just dismissed.
        if let closedAt = lastPanelCloseAt, ContinuousClock.now - closedAt < .milliseconds(250) {
            return
        }
        guard let anchor = panelAnchor() else { return }
        // Mark the panel presented and force one full sample before the
        // window appears: the body builds from the (live) snapshot the
        // moment the flag flips, and the process ranking is not sampled
        // while the panel is hidden — without the forced tick the first
        // frame would show empty rankings until the next polling tick.
        viewModel.setPanelPresented(true)
        viewModel.sampleSystemStats(force: true)
        // Seed the first frame from the last measurement so the panel opens
        // at its final size; the geometry callback keeps it in sync
        // afterwards. The zero-height fallbacks only matter before the
        // first measure — a wrong-but-visible panel beats a zero-sized one.
        let seed: CGSize
        if let measured = lastMeasuredContentSize, measured.height > 0 {
            seed = measured
        } else if let preferred = panel.contentViewController?.preferredContentSize, preferred.height > 0 {
            seed = preferred
        } else {
            seed = CGSize(width: 360, height: 420)
        }
        panel.setFrame(panelFrame(anchoredTo: anchor, size: seed), display: false)
        panel.orderFrontRegardless()
        startDismissalMonitor()
    }

    /// The status item's button rectangle in screen coordinates — the
    /// anchor the panel's top edge hangs from. nil while the button is not
    /// in a window yet.
    private func panelAnchor() -> NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// The panel's frame: centered on the status item's button, hung
    /// directly below the menu bar, clamped so it stays on screen.
    ///
    /// The panel has no arrow, so anchoring the frame's top edge to the
    /// button's bottom edge hangs it flush under the menu bar instead of
    /// leaving a gap for chrome that does not exist.
    private func panelFrame(anchoredTo anchor: NSRect, size: CGSize) -> NSRect {
        var origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height)
        if let visible = (statusItem.button?.window?.screen ?? NSScreen.main)?.visibleFrame {
            let minimumX = visible.minX + 8
            origin.x = min(max(origin.x, minimumX), max(minimumX, visible.maxX - size.width - 8))
            origin.y = max(origin.y, visible.minY + 8)
        }
        return NSRect(origin: origin, size: size)
    }

    /// Close the panel on any mouse-down outside the app — the popover's
    /// transient behavior, reproduced.
    ///
    /// A global monitor never sees this app's own events, so clicks inside
    /// the panel or on the status item keep it open, while a click on
    /// another process's window (including the main Mackit process, which
    /// is separate) dismisses it. Mouse-down monitors need no accessibility
    /// trust; only keyboard ones do.
    private func startDismissalMonitor() {
        guard dismissalMonitor == nil else { return }
        dismissalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleOutsideClick()
            }
        }
        if dismissalMonitor == nil {
            // The mouse-down tap could not be installed: the panel still
            // closes through the status-item toggle and its own buttons,
            // but a click elsewhere no longer dismisses it — the one
            // behavior the popover provided for free. Worth a log line;
            // there is no fallback tap to install instead.
            MackitLog.ui.error("tray panel dismissal monitor could not be installed")
        }
    }

    private func stopDismissalMonitor() {
        if let dismissalMonitor {
            NSEvent.removeMonitor(dismissalMonitor)
        }
        dismissalMonitor = nil
    }

    private func handleOutsideClick() {
        guard panel.isVisible else { return }
        closePanel()
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
        if panel.isVisible { closePanel() }
        guard let button = statusItem.button else { return }

        let state = TrayMenuState(
            updateEnabled: UpdateController.isEnabled(feedURL: AppBridge.mainAppUpdateFeedURL()),
            showCPU: viewModel.showMenuBarCPU,
            showMemory: viewModel.showMenuBarMemory,
            showTemperature: viewModel.showMenuBarTemperature
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
        case .checkUpdates:
            AppBridge.send(.checkUpdates)
        case .about:
            // The same standard About panel the main window's app menu
            // shows; the agent activates itself for it, or the panel would
            // open behind other windows of an app that cannot activate on
            // its own.
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(options: Self.aboutPanelOptions())
        case .quit:
            viewModel.quitFromTray()
        }
    }

    // MARK: - About panel

    /// The identity the standard About panel would otherwise get wrong.
    ///
    /// With no options the panel reads everything from the running bundle —
    /// the agent bundle, which is named "Mackit Agent" and carries no icon
    /// of its own (LSUIElement never enters the Dock). The user opens
    /// About through Mackit's menu bar presence, so the name and icon are
    /// overridden with the product's; version and copyright already come
    /// from the same Info.plist the main app uses and need no override.
    private static func aboutPanelOptions() -> [NSApplication.AboutPanelOptionKey: Any] {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: AppIdentity.productName
        ]
        // The icns is copied into the agent bundle's Resources by
        // Scripts/build-app.sh. A missing file leaves the default generic
        // icon rather than failing the panel.
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            options[.applicationIcon] = icon
        }
        return options
    }

    // MARK: - Label image and observation

    /// Redraw the template stats image. Reads the throttled snapshot — the
    /// loop re-renders it on each change, so it must not read live values
    /// (the throttling comment lives on `publishMenuSnapshot`).
    ///
    /// The image is re-rasterized only when something it draws has changed:
    /// the observation loop fires on every publish (at least every two
    /// seconds), and laying out identical text plus handing the same image
    /// to the menu bar item again is pure waste.
    private func updateLabel() {
        let labelMetrics = metrics
        let height = menuBarHeight
        let showLogo = viewModel.showMenuBarLogo
        if let last = lastLabelInputs,
           last.0 == labelMetrics, last.1 == height, last.2 == showLogo {
            return
        }
        lastLabelInputs = (labelMetrics, height, showLogo)
        statusItem.button?.image = MenuBarStatsImage.image(
            metrics: labelMetrics,
            barHeight: height,
            showIcon: showLogo
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
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.stateDidChange()
            }
        }
    }

    private func stateDidChange() {
        updateLabel()
        observeState()
    }
}
