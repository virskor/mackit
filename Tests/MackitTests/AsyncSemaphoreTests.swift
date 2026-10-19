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
        #expect(peak <= 3, "并发峰值 \(peak) 超过上限 3")
        #expect(peak > 0, "从未进入临界区")
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
        #expect(peak == 1, "max=1 时峰值应为 1，实际 \(peak)")
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
        #expect(count == 25, "应有 25 个任务完成，实际 \(count)")
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
