import Foundation
import os

/// The shared work queue of the directory walks.
///
/// Workers take batches of directories, walk them, and hand the batch back
/// through `record`. A drained queue cannot tell a worker the walk is over on
/// its own — another worker may be mid-enumeration with children still to
/// push — so `working` tracks the workers holding a batch right now, and only
/// an empty queue with none of them busy ends the walk. Same shape, and same
/// reasoning, as the disk analysis counting pass's queue.
///
/// A lock rather than an actor: `push` runs once per batch, and the actor hop
/// is cheap at that rate, but `nextBatch`'s take-and-count must be one atomic
/// step — a worker that took a batch without yet counting itself busy would
/// let another conclude the walk is over and exit with that batch's
/// subdirectories never walked.
final class ScanWalkQueue: Sendable {
    private struct State {
        var pending: [String] = []
        /// Workers holding a batch right now — between taking one and handing
        /// its result back. Subdirectories are pushed only while a batch is
        /// held, so an empty queue with none of them means everything
        /// discovered has been visited: the walk is over, not waiting.
        var working = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// How many directories one worker takes per lock acquisition. Batching
    /// keeps the lock traffic next to the enumerations rather than per
    /// directory.
    private static let batchSize = 64

    init(root: String) {
        state.withLock { $0.pending = [root] }
    }

    /// The next batch of directories, or nil when the walk is over.
    func nextBatch() async -> [String]? {
        while true {
            let outcome = state.withLock { state -> Outcome? in
                guard !state.pending.isEmpty else {
                    return state.working == 0 ? .done : nil
                }
                let size = min(Self.batchSize, state.pending.count)
                let batch = Array(state.pending.suffix(size))
                state.pending.removeLast(size)
                state.working += 1
                return .batch(batch)
            }
            switch outcome {
            case .batch(let batch):
                return batch
            case .done:
                return nil
            case nil:
                if Task.isCancelled { return nil }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
    }

    func push(contentsOf paths: [String]) {
        guard !paths.isEmpty else { return }
        state.withLock { $0.pending.append(contentsOf: paths) }
    }

    /// Hands a finished batch back. Taking the worker off `working` here —
    /// after its subdirectories are already in the queue — is what makes the
    /// empty-queue check above sound.
    func record() {
        state.withLock { $0.working -= 1 }
    }

    private enum Outcome {
        case batch([String])
        case done
    }
}
