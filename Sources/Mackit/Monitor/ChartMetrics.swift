/// The processor page's chart window.
enum CPUChartRange: String, CaseIterable, Identifiable, Sendable {
    case live
    case fifteenMinutes
    case oneHour
    case twentyFourHours

    var id: String { rawValue }

    /// Localization key for the segmented control.
    var titleKey: String {
        switch self {
        case .live: return "panel.processor.range.live"
        case .fifteenMinutes: return "panel.processor.range.15m"
        case .oneHour: return "panel.processor.range.1h"
        case .twentyFourHours: return "panel.processor.range.24h"
        }
    }

    /// How many 2-second samples this window covers, capped by the history
    /// capacity (24 hours is the widest window the view model retains).
    var sampleCount: Int {
        switch self {
        case .live: return 60
        case .fifteenMinutes: return 450
        case .oneHour: return 1_800
        case .twentyFourHours: return 43_200
        }
    }

    /// Samples are downsampled to this many points before reaching the chart.
    static let chartPointCount = 60
}

/// The memory page's chart metric.
enum MemoryChartMetric: String, CaseIterable, Identifiable, Sendable {
    case used
    case compressed
    case swap

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .used: return "panel.memory.metric.used"
        case .compressed: return "panel.memory.metric.compressed"
        case .swap: return "panel.memory.metric.swap"
        }
    }
}
