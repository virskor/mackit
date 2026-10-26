import Foundation
import Testing

@testable import Mackit

/// Verifies that the semaphore really limits concurrency and does not deadlock.
struct AsyncSemaphoreTests {
    @Test func limitsConcurrency() async throws {
        let semaphore = AsyncSemaphore(max: 3)
        let counter = ConcurrencyCounter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<30 {
                group.addTask {
                    await semaphore.withPermit {
                        await counter.enter()
                        // Simulate time-consuming work
                        try? await Task.sleep(nanoseconds: 20_000_000)
                        await counter.exit()
                    }
                }
            }
        }

        let peak = await counter.peak
        #expect(peak <= 3, "peak concurrency \(peak) exceeds the limit of 3")
        #expect(peak > 0, "never entered the critical section")
    }

    @Test func serialModeDoesNotDeadlock() async throws {
        let semaphore = AsyncSemaphore(max: 1)
        let counter = ConcurrencyCounter()

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<10 {
                group.addTask {
                    await semaphore.withPermit {
                        await counter.enter()
                        await counter.exit()
                        _ = index
                    }
                }
            }
        }

        let peak = await counter.peak
        #expect(peak == 1, "peak should be 1 when max=1, got \(peak)")
    }

    @Test func allTasksComplete() async throws {
        let semaphore = AsyncSemaphore(max: 4)
        let completed = CompletedCounter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<25 {
                group.addTask {
                    await semaphore.withPermit {
                        await completed.mark()
                    }
                }
            }
        }

        let count = await completed.count
        #expect(count == 25, "25 tasks should complete, got \(count)")
    }

    // MARK: - Cancellation while waiting

    /// A task told to stop while it waits for a permit must leave the queue
    /// instead of staying parked. `withCheckedContinuation` has no
    /// cancellation support of its own, so without the semaphore's own
    /// handling a cancelled task waits for a permit nobody will hand it — and
    /// the scan's "Stop" never takes effect.
    @Test(.timeLimit(.minutes(1))) func aTaskCancelledWhileParkedLeavesWithoutAPermit() async throws {
        let semaphore = AsyncSemaphore(max: 1)
        let entered = EnteredCounter()

        // Occupy the only permit for as long as this test runs.
        let holder = Task {
            await semaphore.withPermit {
                await entered.mark()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        // Wait until the permit is genuinely held, so the waiters below park
        // rather than grabbing it.
        while await entered.count == 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }

        let parked = Task {
            await semaphore.withPermit {
                await entered.mark()
                return "ran"
            }
        }
        // Give the waiter time to reach the queue, then stop it.
        try? await Task.sleep(for: .milliseconds(50))
        parked.cancel()

        // The cancelled waiter must not run its body — and must not deadlock
        // the holder, which is what a permit never released would do.
        let result = await parked.value
        #expect(result == nil, "a cancelled waiter ran its body anyway")
        holder.cancel()
        _ = await holder.value
    }

    /// A task that is already cancelled when it arrives must not park at all:
    /// the cancellation handler fires before the wait begins, so the park has
    /// to notice for itself.
    @Test(.timeLimit(.minutes(1))) func aTaskCancelledBeforeParkingReturnsImmediately() async throws {
        let semaphore = AsyncSemaphore(max: 1)
        let entered = EnteredCounter()

        let holder = Task {
            await semaphore.withPermit {
                await entered.mark()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        while await entered.count == 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }

        let alreadyCancelled = Task {
            try? await Task.sleep(for: .milliseconds(20))
            return await semaphore.withPermit { "ran" }
        }
        alreadyCancelled.cancel()

        #expect(await alreadyCancelled.value == nil, "an already-cancelled task ran its body")

        holder.cancel()
        _ = await holder.value
    }

    /// Cancelling one waiter must not disturb the others: the permit it would
    /// have taken still reaches the next waiter in line, and the queue drains.
    @Test(.timeLimit(.minutes(1))) func cancellingOneWaiterLeavesTheQueueDraining() async throws {
        let semaphore = AsyncSemaphore(max: 1)
        let completed = CompletedCounter()

        let holder = Task {
            await semaphore.withPermit {
                try? await Task.sleep(for: .seconds(30))
            }
        }
        // Park three waiters; the middle one is stopped.
        let first = Task { await semaphore.withPermit { await completed.mark() } }
        let stopped = Task { await semaphore.withPermit { await completed.mark() } }
        let last = Task { await semaphore.withPermit { await completed.mark() } }
        try? await Task.sleep(for: .milliseconds(50))
        stopped.cancel()

        // Free the permit: the two survivors must both get through.
        holder.cancel()
        _ = await holder.value
        _ = await first.value
        _ = await stopped.value
        _ = await last.value

        let count = await completed.count
        #expect(count == 2, "both surviving waiters should have run, got \(count)")
    }

    /// A cancelled waiter must not leak the permit it never took. The count has
    /// to come back down, or the semaphore eventually admits nothing at all and
    /// every later scan parks forever — a failure that only surfaces long after
    /// the cancel that caused it.
    @Test(.timeLimit(.minutes(1))) func aCancelledWaiterLeaksNoPermit() async throws {
        let semaphore = AsyncSemaphore(max: 1)
        let entered = EnteredCounter()

        let holder = Task {
            await semaphore.withPermit {
                await entered.mark()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        while await entered.count == 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }

        // Several waiters, every one stopped: none may leave the count raised,
        // and none may take a permit it then drops on the floor.
        var cancelled: [Task<String?, Never>] = []
        for index in 0..<5 {
            cancelled.append(Task { await semaphore.withPermit { "ran \(index)" } })
        }
        try? await Task.sleep(for: .milliseconds(50))
        for task in cancelled { task.cancel() }
        for task in cancelled {
            #expect(await task.value == nil, "a cancelled waiter ran its body")
        }
        holder.cancel()
        _ = await holder.value

        // The semaphore must still hand out its one permit on demand. A leaked
        // permit parks this task forever, which the time limit turns into a
        // failure rather than a hung suite.
        let late = Task { await semaphore.withPermit { "ran late" } }
        #expect(await late.value == "ran late", "the semaphore stopped admitting work — a permit leaked")
    }
}

/// Counts how many times a body ran, so a test can prove a cancelled waiter
/// never entered its critical section.
private actor EnteredCounter {
    private(set) var count = 0

    func mark() {
        count += 1
    }
}

/// A thread-safe concurrency counter, used to test semaphore behavior.
private actor ConcurrencyCounter {
    private(set) var current = 0
    private(set) var peak = 0

    func enter() {
        current += 1
        if current > peak { peak = current }
    }

    func exit() {
        current -= 1
    }
}

private actor CompletedCounter {
    private(set) var count = 0

    func mark() { count += 1 }
}
