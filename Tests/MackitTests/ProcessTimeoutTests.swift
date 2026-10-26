import Darwin
import Foundation
import Testing

@testable import Mackit

/// The subprocess timeout has to actually end the call it bounds.
///
/// `Process.terminate()` is one SIGTERM, and a child that ignores it keeps its
/// pipes open — which keeps every reader downstream blocked, because
/// `readDataToEndOfFile` only returns at EOF. The escalation to SIGKILL is what
/// makes the timeout an end rather than a suggestion, so it is tested against a
/// real child that really refuses to die politely.
struct ProcessTimeoutTests {
    /// A child that outlives its timeout, sleeping well past it.
    private func makeSleeper(_ seconds: Int) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["\(seconds)"]
        try process.run()
        return process
    }

    /// A child that traps SIGTERM and keeps sleeping: the shape of a brew
    /// stuck on a lock, or a hung launchctl, where the polite signal never
    /// lands. Only a signal it cannot trap can end it.
    private func makeStubbornSleeper(_ seconds: Int) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; sleep \(seconds)"]
        try process.run()
        return process
    }

    /// Polls until the child is gone, or the budget runs out.
    private func waitUntilExited(_ process: Process, within budget: Duration) async -> Bool {
        let deadline = ContinuousClock.now + budget
        while process.isRunning {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// Leaves no stray child behind, whatever the test proved.
    private func cleanup(_ process: Process) {
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
        }
    }

    @Test func aTimeoutTerminatesARunawayChild() async throws {
        let process = try makeSleeper(60)
        defer { cleanup(process) }
        let task = ProcessTimeout.enforce(.milliseconds(100), on: process)
        defer { task.cancel() }

        #expect(
            await waitUntilExited(process, within: .seconds(5)),
            "the child outlived its timeout"
        )
    }

    /// The whole point of the escalation: a child that ignores SIGTERM must
    /// still be gone once the grace expires, or the caller's readers stay
    /// blocked on pipes that never reach EOF. The child traps TERM, so a
    /// process that is gone at all is proof the kill landed.
    @Test func aChildThatIgnoresSIGTERMIsKilled() async throws {
        let process = try makeStubbornSleeper(60)
        defer { cleanup(process) }
        let task = ProcessTimeout.enforce(
            .milliseconds(100),
            on: process,
            killGrace: .milliseconds(200)
        )
        defer { task.cancel() }

        #expect(
            await waitUntilExited(process, within: .seconds(10)),
            "the stubborn child outlived the SIGKILL"
        )
    }

    /// A child that exits on its own must not be touched: cancelling the
    /// enforcement leaves it running, and a spurious SIGKILL on a healthy brew
    /// would abort a clean the user is watching.
    @Test func aHealthyChildIsLeftAloneOnceTheTimeoutIsCancelled() async throws {
        let process = try makeSleeper(60)
        defer { cleanup(process) }
        let task = ProcessTimeout.enforce(.milliseconds(100), on: process)
        task.cancel()

        // Well past the timeout: the cancelled enforcement must not fire.
        try? await Task.sleep(for: .milliseconds(500))
        #expect(process.isRunning, "a cancelled timeout killed a healthy child")
    }

    /// The timeout must not fire at all for a child that finishes in time —
    /// the `isRunning` guard is what keeps a fast clean from paying the grace
    /// period and signalling a process that already exited.
    @Test func aChildThatFinishesInTimeIsNotSignalled() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0"]
        try process.run()

        let task = ProcessTimeout.enforce(.milliseconds(100), on: process, killGrace: .milliseconds(100))
        defer { task.cancel() }

        try? await Task.sleep(for: .milliseconds(300))
        #expect(!process.isRunning)
        process.waitUntilExit()
        #expect(process.terminationReason == .exit, "a child that exited cleanly must not be reported as killed")
    }
}
