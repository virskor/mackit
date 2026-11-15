import Testing

@testable import Mackit

/// The ring buffer behind the panel's CPU and memory history charts.
///
/// A chart only sees what `suffix` and `downsampled` return, so a wrap-around
/// mistake or a bucket boundary that is off by one plots the wrong seconds
/// without crashing. These tests pin the chronological order at the wrap
/// point and the bucket arithmetic before values reach the chart.
struct MetricHistoryTests {
    // MARK: Empty and short histories

    @Test func emptyHistoryReturnsNoData() {
        let history = MetricHistory(capacity: 8)

        #expect(history.count == 0)
        #expect(history.values.isEmpty)
        #expect(history.suffix(4).isEmpty)
        #expect(history.downsampled(maxPoints: 4).isEmpty)
    }

    /// A history holding no more points than the chart asked for must pass
    /// through untouched: averaging would blur a window that is already
    /// small enough to draw point by point.
    @Test func downsampledLeavesShortInputUnchanged() {
        var history = MetricHistory(capacity: 10)
        for value in [0.25, 0.5, 0.75] {
            history.append(value)
        }

        #expect(history.downsampled(maxPoints: 3) == [0.25, 0.5, 0.75])
        #expect(history.downsampled(maxPoints: 10) == [0.25, 0.5, 0.75])
    }

    // MARK: Ring buffer order

    /// Once the buffer is full, appending must evict the oldest value, not
    /// the newest: the chart always shows the most recent window.
    @Test func appendingPastCapacityKeepsNewestValuesInOrder() {
        var history = MetricHistory(capacity: 3)
        for value in [10.0, 20.0, 30.0, 40.0, 50.0] {
            history.append(value)
        }

        #expect(history.capacity == 3)
        #expect(history.count == 3)
        #expect(history.values == [30.0, 40.0, 50.0])
        #expect(history.suffix(2) == [40.0, 50.0])
    }

    @Test func capacityOneKeepsOnlyTheLastValue() {
        var history = MetricHistory(capacity: 1)
        history.append(1.0)
        history.append(2.0)
        history.append(3.0)

        #expect(history.count == 1)
        #expect(history.values == [3.0])
        #expect(history.suffix(10) == [3.0])
    }

    /// The suffix is the newest N values in chronological order — the same
    /// direction the chart draws them, oldest at the left.
    @Test func suffixReturnsNewestValuesChronologically() {
        var history = MetricHistory(capacity: 5)
        for value in [1.0, 2.0, 3.0, 4.0, 5.0] {
            history.append(value)
        }

        #expect(history.suffix(2) == [4.0, 5.0])
        #expect(history.suffix(5) == [1.0, 2.0, 3.0, 4.0, 5.0])
        // Asking for more values than the history holds returns all of them.
        #expect(history.suffix(99) == [1.0, 2.0, 3.0, 4.0, 5.0])
    }

    /// The production chart path asks for a window and a point count in one
    /// step; it must bucket the requested suffix in ring order without first
    /// materializing it as an array.
    @Test func seriesDownsamplesOnlyTheRequestedWindow() {
        var history = MetricHistory(capacity: 6)
        for value in [1.0, 2, 3, 4, 5, 6] {
            history.append(value)
        }

        #expect(history.series(maxCount: 4, maxPoints: 2) == [3.5, 5.5])
        #expect(history.series(maxCount: 99, maxPoints: 3) == [1.5, 3.5, 5.5])
        // A window no longer than the point count passes through unchanged.
        #expect(history.series(maxCount: 2, maxPoints: 10) == [5, 6])
        #expect(history.series(maxCount: 0, maxPoints: 10).isEmpty)
    }

    /// `series` must read through the wrap point in chronological order, the
    /// same way the full-history downsample does.
    @Test func seriesReadsThroughTheWrapPoint() {
        var history = MetricHistory(capacity: 4)
        for value in [1.0, 2, 3, 4, 5, 6] {
            history.append(value)
        }

        // The buffer holds 3, 4, 5, 6; the newest three are 4, 5, 6.
        #expect(history.series(maxCount: 3, maxPoints: 2) == [4, 5.5])
    }

    // MARK: Downsampling

    /// Four values into two buckets average two adjacent values each; the
    /// order inside each bucket is chronological, so the first bucket holds
    /// the older pair.
    @Test func downsampledAveragesContiguousBuckets() {
        var history = MetricHistory(capacity: 4)
        for value in [0.0, 1.0, 2.0, 3.0] {
            history.append(value)
        }

        #expect(history.downsampled(maxPoints: 2) == [0.5, 2.5])
        #expect(history.downsampled(maxPoints: 1) == [1.5])
    }

    /// Downsampling after a wrap must bucket the chronological values, not
    /// the underlying ring storage, which starts in the middle.
    @Test func downsampledUsesChronologicalOrderAfterWrap() {
        var history = MetricHistory(capacity: 4)
        for value in [1.0, 2.0, 3.0, 4.0, 5.0, 6.0] {
            history.append(value)
        }

        #expect(history.values == [3.0, 4.0, 5.0, 6.0])
        #expect(history.downsampled(maxPoints: 2) == [3.5, 5.5])
    }

    /// The chart has a fixed number of columns; downsampling must never hand
    /// it more points than requested, however many values are buffered.
    @Test func downsampledNeverExceedsRequestedPointCount() {
        var history = MetricHistory(capacity: 10)
        for value in 0..<10 {
            history.append(Double(value))
        }

        let points = history.downsampled(maxPoints: 3)

        #expect(points.count <= 3)
        #expect(points.count >= 1)
        // Every bucket average stays inside the original value range.
        #expect(points.allSatisfy { $0 >= 0 && $0 <= 9 })
    }
}
