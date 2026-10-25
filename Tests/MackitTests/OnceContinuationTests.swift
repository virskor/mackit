import Foundation
import Testing

@testable import Mackit

/// The once-guard both subprocess waits resume through: a process exiting
/// between the `terminationHandler` install and the `isRunning` check fires
/// both resume paths, and an unguarded second resume would trap.
struct OnceContinuationTests {
    @Test func theFirstResumeWinsAndALateSecondIsANoOp() async {
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            let once = OnceContinuation(continuation)
            once.resume(returning: 0)
            // The racing fallback path: swallowed, not a trap.
            once.resume(returning: 1)
        }
        #expect(status == 0)
    }

    @Test func concurrentResumesProduceExactlyOneValue() async {
        // Two detached tasks racing the resume; whichever wins, the
        // continuation completes exactly once with that value.
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            let once = OnceContinuation(continuation)
            Task.detached { once.resume(returning: 7) }
            Task.detached { once.resume(returning: 7) }
        }
        #expect(status == 7)
    }
}
