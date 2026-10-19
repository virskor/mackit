import AppKit
import SwiftUI

/// Desktop floating stats window: a compact value bar that stays at the top of the desktop.
///
/// Mackit's own take on the compact floating style others use: values on top, short
/// labels below, a thin divider between groups, white text with a faint shadow — no
/// backdrop plate, so it stays readable on any wallpaper and doesn't block what's
/// behind it. Exists only in the tray agent process: it must keep running after the
/// main app quits, for the same reason the menu bar panel is split off (see `AgentApp`).
///
/// The position is persisted separately (`OverlayPositionStore`) rather than written
/// into the shared settings: only the agent drags it, while shared settings are a
/// single-point "read-modify-write" in the main app; two concurrent write paths would
/// overwrite each other — the user drags the overlay while flipping a switch in
/// settings, and one of the two changes would be lost.
@MainActor
final class StatsOverlayController: NSObject {
    /// In-process singleton. There is only one overlay globally; position and
    /// visibility are both global state.
    static let shared = StatsOverlayController()

    /// Borderless panel that hosts the content, created lazily; when turned off
    /// in settings it only `orderOut`s without being destroyed — no rebuild
    /// needed on reopen, and the position is naturally preserved.
    private var panel: StatsOverlayPanel?
    /// The VM currently hosted by the panel. Normally there is only one VM and it
    /// lives as long as the process; if it truly changes (repeated `attach` in
    /// tests), rebuild content and panel together so the panel doesn't keep
    /// showing the old VM's numbers.
    private var hostedVM: AppViewModel?

    private override init() {
        super.init()
        // After unplugging a display or changing resolution, the last recorded
        // position may land in a visible area that no longer exists — if we don't
        // clamp it back, the overlay is "lost" and the user has to fall back to
        // the default position.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    // MARK: - Display control

    /// Attach the VM and show/hide according to current settings. Called once when
    /// the menu bar label appears (the label lives with the process, making it a
    /// natural mount point).
    func attach(_ vm: AppViewModel) {
        if hostedVM !== vm {
            // The old panel must be closed first: NSApp holds onto the window
            // object; just nil-ing the reference would leak it in the window table.
            panel?.close()
            panel = nil
            hostedVM = vm
        }
        sync()
    }

    /// Show / retract according to current settings. Called after settings
    /// changes (the master switch and the three monitor switches).
    func sync() {
        guard let vm = hostedVM else { return }
        if vm.statsOverlayVisible {
            present(vm)
        } else {
            dismiss()
        }
    }

    private func present(_ vm: AppViewModel) {
        let panel = panel ?? makePanel(vm: vm)
        self.panel = panel
        // Only position the panel when it goes "from nothing to something": a
        // settings refresh causes sync to be called repeatedly; if the user is
        // mid-drag, the panel must not be yanked back to the default position.
        if !panel.isVisible {
            panel.setFrameOrigin(restoredOrigin(for: panel))
        }
        panel.orderFront(nil)
    }

    private func dismiss() {
        panel?.orderOut(nil)
    }

    // MARK: - Size and position

    private func makePanel(vm: AppViewModel) -> StatsOverlayPanel {
        // The initial size is just a placeholder: once the content is laid out it
        // collapses to the real size per fittingSize, and the position is only
        // decided after that collapse — the default position is computed from the
        // final size.
        let panel = StatsOverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 48))
        panel.contentView = NSHostingView(
            rootView: StatsOverlayContentView(vm: vm, controller: self)
        )
        fitContent(of: panel)
        return panel
    }

    /// Collapse the panel to the content's intrinsic size, pinning the top edge.
    ///
    /// The content width changes ("9%" → "100%", "Normal" → "Critical"); without
    /// collapsing along with it, the panel would leave a blank patch or clip the
    /// content. Sub-half-pixel jitter is skipped outright: the monitor pushes an
    /// update every two seconds, and calling setFrame every time burns the main
    /// thread for nothing.
    private func fitContent(of panel: StatsOverlayPanel) {
        guard let hosting = panel.contentView as? NSHostingView<StatsOverlayContentView> else { return }
        hosting.layoutSubtreeIfNeeded()
        applyContentSize(hosting.fittingSize, to: panel)
    }

    /// The content view reports its own size via GeometryReader, same path as
    /// `fitContent`.
    func resize(to contentSize: CGSize) {
        guard let panel else { return }
        applyContentSize(contentSize, to: panel)
    }

    private func applyContentSize(_ size: CGSize, to panel: StatsOverlayPanel) {
        guard size.width > 0, size.height > 0 else { return }
        let current = panel.frame
        guard abs(current.width - size.width) > 0.5 || abs(current.height - size.height) > 0.5 else { return }
        var frame = current
        // origin.y is the bottom-left corner: keeping the top edge fixed means
        // raising the origin by the amount the height grew
        frame.origin.y += current.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
    }

    /// Drag delta. Screen coordinates have y pointing up while SwiftUI drag
    /// translation y points down, so negate.
    func nudge(dx: CGFloat, dy: CGFloat) {
        guard let panel, dx != 0 || dy != 0 else { return }
        var origin = panel.frame.origin
        origin.x += dx
        origin.y -= dy
        panel.setFrameOrigin(clamped(origin, size: panel.frame.size))
    }

    /// Drag ended: persist the position.
    func persistPosition() {
        guard let panel else { return }
        OverlayPositionStore.save(panel.frame.origin)
    }

    private func restoredOrigin(for panel: StatsOverlayPanel) -> NSPoint {
        if let stored = OverlayPositionStore.load() {
            return clamped(stored, size: panel.frame.size)
        }
        return defaultOrigin(size: panel.frame.size)
    }

    /// Position on first display: centered at the top of the visible frame of the
    /// screen containing the mouse (main screen if unavailable), leaving 8pt below
    /// the menu bar. Centered because this content is narrow; hugging an edge
    /// would look like a band-aid.
    private func defaultOrigin(size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: mouse.x, y: mouse.y)) }
            ?? NSScreen.main
        guard let screen else { return .zero }
        let visible = screen.visibleFrame
        return NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 8)
    }

    /// Clamp the origin back into some screen's visible frame: after dragging
    /// off-screen or a screen configuration change, the panel must at least stay
    /// fully somewhere visible.
    private func clamped(_ origin: NSPoint, size: NSSize) -> NSPoint {
        let point = CGPoint(x: origin.x, y: origin.y)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else {
            return origin
        }
        let visible = screen.visibleFrame
        let maxX = visible.maxX - size.width
        let maxY = visible.maxY - size.height
        // When the panel is larger than the visible frame (extreme multi-screen
        // stacking), return to the top-left corner rather than pushing it off-screen
        return NSPoint(
            x: maxX >= visible.minX ? min(max(origin.x, visible.minX), maxX) : visible.minX,
            y: maxY >= visible.minY ? min(max(origin.y, visible.minY), maxY) : visible.minY
        )
    }

    @objc private func screenParametersChanged() {
        guard let panel, panel.isVisible else { return }
        panel.setFrameOrigin(clamped(panel.frame.origin, size: panel.frame.size))
    }
}

/// The panel that hosts the floating stats window.
///
/// Borderless + non-activating: clicking it is only to view numbers or drag, it
/// shouldn't switch the user's current app to the background, nor should it paint
/// a system-default window background. `isMovable` is off — movement is driven
/// entirely by SwiftUI gestures (it needs to record the position and stay clamped
/// on screen); handing dragging over to AppKit would leave the position
/// uncontrolled.
final class StatsOverlayPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        // Show on every desktop space; preserved in auxiliary form next to
        // full-screen apps, so viewing numbers doesn't require switching spaces
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
}

/// Overlay content: values on top, short labels below, a thin divider between
/// groups.
struct StatsOverlayContentView: View {
    let vm: AppViewModel
    let controller: StatsOverlayController

    /// The cumulative translation reported by the last drag event. The gesture
    /// moves the window by "the difference from last time", so the starting point
    /// doesn't need to be kept in state separately.
    @State private var lastTranslation: CGSize = .zero

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            // The three items each appear according to their own switch. When all
            // are off the overlay is retracted anyway (see
            // `AppViewModel.statsOverlayVisible`), so no emptiness check is done here.
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                if index > 0 { separator }
                metric(value: entry.value, label: entry.label)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .foregroundStyle(.white)
        // White text sits directly on the wallpaper, where it washes out on light
        // wallpapers — add a very faint dark shadow
        .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
        .fixedSize()
        .background(
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size) { _, size in
                    controller.resize(to: size)
                }
            }
        )
        .gesture(dragGesture)
    }

    /// The current values and short labels of the three monitor items, in fixed
    /// order, filtered by the switches.
    private var entries: [(value: String, label: String)] {
        var result: [(value: String, label: String)] = []
        if vm.showMenuBarCPU {
            result.append((cpuValue, L10n.tr("menubar.cpu")))
        }
        if vm.showMenuBarMemory {
            result.append((memoryValue, L10n.tr("menubar.memory")))
        }
        if vm.showMenuBarTemperature {
            result.append((thermalValue, L10n.tr("menubar.temperature")))
        }
        return result
    }

    private var cpuValue: String {
        vm.stats.cpuUsage.map(Formatters.percent) ?? "—"
    }

    private var memoryValue: String {
        guard vm.stats.memoryTotal > 0 else { return "—" }
        return Formatters.percent(vm.stats.memoryUsedFraction)
    }

    private var thermalValue: String {
        L10n.tr(vm.stats.thermalStateKey)
    }

    /// One "value + short label" group. The value uses monospaced digits: the
    /// width doesn't change when it jumps, so the dividers on both sides don't
    /// shake along.
    private func metric(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(verbatim: value)
                .font(.system(size: 20, weight: .semibold))
                .monospacedDigit()
            Text(verbatim: label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    /// Divider between groups: a 1pt thin line, height close to two lines of text.
    private var separator: some View {
        Rectangle()
            .fill(.white.opacity(0.3))
            .frame(width: 1, height: 28)
            .padding(.horizontal, 12)
    }

    /// Dragging moves the panel; a light tap (movement under 4pt) opens the main
    /// window.
    ///
    /// The panel itself has `isMovable = false`, so all movement goes through
    /// here: each event moves by the delta from last time, clamped on screen, and
    /// persisted on release. Tap and drag are distinguished by the same gesture —
    /// `minimumDistance` guarantees a tap doesn't trigger `onChanged`.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let dx = value.translation.width - lastTranslation.width
                let dy = value.translation.height - lastTranslation.height
                lastTranslation = value.translation
                controller.nudge(dx: dx, dy: dy)
            }
            .onEnded { value in
                lastTranslation = .zero
                if abs(value.translation.width) < 4, abs(value.translation.height) < 4 {
                    vm.openMainWindowFromTray()
                } else {
                    controller.persistPosition()
                }
            }
    }
}

/// Persistence of the overlay position. The file path is injectable for testing.
///
/// Why a separate file instead of merging into shared settings: settings are a
/// single-point "read-modify-write" in the main app, while only the agent writes
/// the position (the overlay lives only in the agent). Two concurrent write paths
/// would overwrite each other between "read-modify-write"s.
@MainActor
enum OverlayPositionStore {
    static let fileURL = SharedStore.directoryURL.appendingPathComponent("overlay-position.plist")

    /// Read back the last position; a missing file or corrupt content both count
    /// as none (fall back to the default position).
    static func load(fileURL: URL = OverlayPositionStore.fileURL) -> NSPoint? {
        guard let dict = NSDictionary(contentsOfFile: fileURL.path),
              let x = dict["x"] as? Double, let y = dict["y"] as? Double,
              x.isFinite, y.isFinite else {
            return nil
        }
        return NSPoint(x: x, y: y)
    }

    /// Record the current position (screen coordinates of the panel's bottom-left corner).
    static func save(_ origin: NSPoint, fileURL: URL = OverlayPositionStore.fileURL) {
        try? FileManager.default.createDirectory(
            at: SharedStore.directoryURL, withIntermediateDirectories: true
        )
        // Persist once per drag; a corrupt write just loses the position: next
        // time it falls back to the default position, which isn't worth throwing
        // an error and interrupting the drag for.
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: ["x": origin.x, "y": origin.y], format: .xml, options: 0
        ) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
