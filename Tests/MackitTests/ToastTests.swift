import Foundation
import Testing

@testable import Mackit

/// Verifies the toast's appearance and auto-dismissal behavior.
@MainActor
struct ToastTests {
    @Test func showToastDisplaysBanner() async {
        let vm = AppViewModel()
        #expect(vm.banner == nil)

        vm.showToast(.success, "已释放 20.54 GB")

        #expect(vm.banner != nil)
        #expect(vm.banner?.message == "已释放 20.54 GB")
        #expect(vm.banner?.style == .success)
    }

    @Test func toastAutoDismisses() async throws {
        let vm = AppViewModel()
        vm.showToast(.error, "无法移入废纸篓")
        #expect(vm.banner != nil)

        // Auto-dismissal is set to 3.5 seconds; wait past that
        try await Task.sleep(nanoseconds: 4_000_000_000)

        #expect(vm.banner == nil, "Toast 应在约 3.5 秒后自动消失")
    }

    @Test func dismissToastClearsImmediately() async {
        let vm = AppViewModel()
        vm.showToast(.success, "测试")
        vm.dismissToast()
        #expect(vm.banner == nil)
    }

    /// When two toasts are shown in a row, the second must replace the first, and no timer task that clears it early is left behind.
    @Test func newToastReplacesPrevious() async throws {
        let vm = AppViewModel()

        vm.showToast(.success, "第一条")
        vm.showToast(.error, "第二条")

        #expect(vm.banner?.message == "第二条")
        #expect(vm.banner?.style == .error)

        // The second toast's own 3.5 seconds have not elapsed yet; it should not disappear now
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(vm.banner?.message == "第二条")

        try await Task.sleep(nanoseconds: 3_000_000_000)
        #expect(vm.banner == nil)
    }

    /// Manually dismissing after auto-dismissal should not crash, nor revive the toast.
    @Test func dismissAfterAutoDismissIsSafe() async throws {
        let vm = AppViewModel()
        vm.showToast(.info, "提示")
        try await Task.sleep(nanoseconds: 4_000_000_000)
        #expect(vm.banner == nil)

        vm.dismissToast()
        #expect(vm.banner == nil)
    }
}
