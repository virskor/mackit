import Foundation

/// A fixed-capacity chronological history of chart values.
///
/// Storage grows on append instead of reserving `capacity` up front: the
/// 24-hour CPU histories hold 43,200 points each, and the view model owns
/// several of them — reserving every capacity at init would allocate
/// megabytes for charts that may never be opened, and tests construct many
/// view models.
struct MetricHistory: Equatable, Sendable {
    /// The most values the history keeps; the oldest is evicted first.
    let capacity: Int
    /// Values in append order until the buffer fills, then wrapped:
    /// `storage[head]` is the oldest value once wrapped.
    private var storage: [Double] = []
    /// Index of the oldest value, meaningful only once `storage` is full.
    private var head = 0

    init(capacity: Int) {
        // A negative capacity cannot describe a window; treat it as "keep
        // nothing" so append stays a no-op instead of trapping on a
        // negative modulo.
        self.capacity = max(0, capacity)
    }

    /// How many values are buffered.
    var count: Int { storage.count }

    /// Chronological values, oldest first.
    var values: [Double] {
        guard head > 0 else { return storage }
        return Array(storage[head...]) + Array(storage[..<head])
    }

    mutating func append(_ value: Double) {
        guard capacity > 0 else { return }
        if storage.count < capacity {
            storage.append(value)
        } else {
            storage[head] = value
            head = (head + 1) % capacity
        }
    }

    /// The newest `maxCount` values, chronological.
    func suffix(_ maxCount: Int) -> [Double] {
        guard maxCount > 0, !storage.isEmpty else { return [] }
        guard maxCount < storage.count else { return values }

        // The requested tail starts `maxCount` values before the newest one.
        // Walking from `head` keeps the result chronological without
        // materializing the whole buffer for a shorter window.
        var result: [Double] = []
        result.reserveCapacity(maxCount)
        let start = storage.count - maxCount
        if head == 0 {
            result.append(contentsOf: storage[start...])
        } else {
            for offset in start..<storage.count {
                result.append(storage[(head + offset) % storage.count])
            }
        }
        return result
    }

    /// Downsamples the newest `maxCount` values into at most `maxPoints`
    /// contiguous buckets, chronological.
    ///
    /// The chart asks for a window and a point count in one step; doing both
    /// here keeps the bucketing in one place. Reading through the ring keeps
    /// the 24-hour window from being copied into an array every publish.
    func series(maxCount: Int, maxPoints: Int) -> [Double] {
        let windowCount = min(max(0, maxCount), storage.count)
        guard windowCount > 0, maxPoints > 0 else { return [] }
        guard windowCount > maxPoints else { return suffix(windowCount) }

        // The window's oldest value is `windowCount` positions before the
        // newest, which is `storage.head + storage.count` in ring order.
        let first = (head + storage.count - windowCount) % storage.count
        return Self.downsample(count: windowCount, maxPoints: maxPoints) { offset in
            storage[(first + offset) % storage.count]
        }
    }

    /// Averages the values into at most `maxPoints` contiguous buckets.
    /// Returns the values unchanged when there are no more than `maxPoints`.
    func downsampled(maxPoints: Int) -> [Double] {
        Self.downsample(count: storage.count, maxPoints: maxPoints) { offset in
            storage[(head + offset) % storage.count]
        }
    }

    /// The shared bucketing behind `series` and `downsampled`.
    ///
    /// `value` reads one chronological index, so a caller can walk the ring
    /// without first materializing a contiguous copy.
    private static func downsample(
        count: Int,
        maxPoints: Int,
        value: (Int) -> Double
    ) -> [Double] {
        guard maxPoints > 0, count > 0 else { return [] }
        guard count > maxPoints else { return (0..<count).map(value) }

        var result: [Double] = []
        result.reserveCapacity(maxPoints)
        for point in 0..<maxPoints {
            // Integer bucket edges keep every value in exactly one bucket;
            // floating-point edges rounded down can leave a bucket empty.
            let start = point * count / maxPoints
            let end = (point + 1) * count / maxPoints
            var sum = 0.0
            for index in start..<end {
                sum += value(index)
            }
            result.append(sum / Double(end - start))
        }
        return result
    }

    /// Equal capacity and equal chronological values; the internal wrap
    /// position is an implementation detail, so two histories fed the same
    /// sequence compare equal however many appends it took to fill them.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.capacity == rhs.capacity && lhs.values == rhs.values
    }
}
