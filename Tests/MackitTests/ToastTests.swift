import Foundation
import Testing

@testable import Mackit

/// Verifies the toast's appearance and auto-dismissal behavior.
@MainActor
struct ToastTests {
    @Test func showToastDisplaysBanner() async {
        let vm = AppViewModel()
        #expect(vm.banner == nil)

        vm.showToast(.success, "Released 20.54 GB")

        #expect(vm.banner != nil)
        #expect(vm.banner?.message == "Released 20.54 GB")
        #expect(vm.banner?.style == .success)
    }

    @Test func toastAutoDismisses() async throws {
        let vm = AppViewModel()
        vm.showToast(.error, "Cannot move to Trash")
        #expect(vm.banner != nil)

        // Auto-dismissal is set to 3.5 seconds; wait past that
        try await Task.sleep(nanoseconds: 4_000_000_000)

        #expect(vm.banner == nil, "the toast should auto-dismiss after about 3.5 seconds")
    }

    @Test func dismissToastClearsImmediately() async {
        let vm = AppViewModel()
        vm.showToast(.success, "Test")
        vm.dismissToast()
        #expect(vm.banner == nil)
    }

    /// When two toasts are shown in a row, the second must replace the first, and no timer task that clears it early is left behind.
    @Test func newToastReplacesPrevious() async throws {
        let vm = AppViewModel()

        vm.showToast(.success, "first")
        vm.showToast(.error, "second")

        #expect(vm.banner?.message == "second")
        #expect(vm.banner?.style == .error)

        // The second toast's own 3.5 seconds have not elapsed yet; it should not disappear now
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(vm.banner?.message == "second")

        try await Task.sleep(nanoseconds: 3_000_000_000)
        #expect(vm.banner == nil)
    }

    /// Manually dismissing after auto-dismissal should not crash, nor revive the toast.
    @Test func dismissAfterAutoDismissIsSafe() async throws {
        let vm = AppViewModel()
        vm.showToast(.info, "notice")
        try await Task.sleep(nanoseconds: 4_000_000_000)
        #expect(vm.banner == nil)

        vm.dismissToast()
        #expect(vm.banner == nil)
    }

    /// Each raised toast gets its own appearance timestamp, so raising the
    /// same message twice — which reuses the banner's id — still re-anchors
    /// the countdown hairline instead of draining the first one's leftover.
    @Test func shownAtAdvancesForRepeatedMessages() async {
        let vm = AppViewModel()
        vm.showToast(.success, "same")
        let first = vm.banner?.shownAt

        vm.showToast(.success, "same")
        let second = vm.banner?.shownAt

        #expect(first != nil && second != nil)
        #expect(second! >= first!)
    }

    /// The regression this pins: every copy affordance except the action log's
    /// used to be silent, so a successful copy was indistinguishable from a
    /// dead button. The pasteboard itself is swapped for a recorder — a test
    /// must not clobber the developer's clipboard.
    @Test func copyingConfirmsItselfWithAToast() {
        let vm = AppViewModel()
        var copied: [String] = []
        vm.pasteboardSink = { text in
            copied.append(text)
        }

        vm.copyToClipboard("brew upgrade")

        #expect(copied == ["brew upgrade"])
        #expect(vm.banner?.style == .success)
        #expect(vm.banner?.message == L10n.tr("toast.copied"))
    }
}

/// The countdown hairline's math, which has to hold without a rendering
/// context.
struct ToastCountdownTests {
    @Test func fullBudgetAtStart() {
        #expect(ToastCountdown.remainingFraction(elapsed: 0, total: 3.5) == 1)
    }

    @Test func halfBudgetAtHalfway() {
        #expect(ToastCountdown.remainingFraction(elapsed: 1.75, total: 3.5) == 0.5)
    }

    /// A timeline tick can land after the view model's timer already cleared
    /// the toast; a negative width would be an invalid frame.
    @Test func elapsedPastBudgetClampsToZero() {
        #expect(ToastCountdown.remainingFraction(elapsed: 4, total: 3.5) == 0)
    }

    /// The first tick can predate the anchor by a hair.
    @Test func elapsedBeforeAnchorClampsToOne() {
        #expect(ToastCountdown.remainingFraction(elapsed: -0.1, total: 3.5) == 1)
    }

    @Test func zeroTotalDoesNotDivideByZero() {
        #expect(ToastCountdown.remainingFraction(elapsed: 1, total: 0) == 0)
    }
}
