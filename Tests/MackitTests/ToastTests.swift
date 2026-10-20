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
}
