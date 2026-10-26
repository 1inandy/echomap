import Foundation

/// Distance bands (plan §5.7).
public enum DistanceBand: Int, Codable, Comparable, CaseIterable, Sendable {
    case urgent = 0   // < 0.5 m
    case near = 1     // 0.5–1.0 m
    case mid = 2      // 1.0–2.0 m
    case far = 3      // 2.0–3.0 m
    case beyond = 4   // > 3.0 m

    public static let boundaries: [Double] = [0.5, 1.0, 2.0, 3.0]

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public static func of(_ d: Double) -> DistanceBand {
        for (i, b) in boundaries.enumerated() where d < b { return DistanceBand(rawValue: i)! }
        return .beyond
    }

    /// Upper edge of this band (nil for beyond).
    var upper: Double? { rawValue < Self.boundaries.count ? Self.boundaries[rawValue] : nil }
    /// Lower edge (nil for urgent).
    var lower: Double? { rawValue > 0 ? Self.boundaries[rawValue - 1] : nil }

    /// Short spoken form, e.g. for VoiceOver announcements on band change.
    public var spoken: String {
        switch self {
        case .urgent: "Very close"
        case .near: "Under one meter"
        case .mid: "One to two meters"
        case .far: "Two to three meters"
        case .beyond: "Nothing near"
        }
    }
}

/// What the haptic engine plays. Pure data; the app turns it into CHHapticPattern events.
public enum HapticPattern: Equatable, Sendable {
    case band(DistanceBand)
    case noReading
    case stopped

    public struct Spec: Equatable, Sendable {
        /// Seconds between pattern repeats (0 = play once).
        public var period: Double
        /// Transient taps within one repeat: offsets in seconds.
        public var taps: [Double]
        public var intensity: Double
        public var sharpness: Double
        /// Continuous buzz duration (stop cue), 0 for none.
        public var buzz: Double
    }

    public var spec: Spec {
        switch self {
        case .band(.urgent): Spec(period: 1 / 10, taps: [0], intensity: 1.0, sharpness: 0.8, buzz: 0)
        case .band(.near): Spec(period: 1 / 5, taps: [0], intensity: 0.8, sharpness: 0.7, buzz: 0)
        case .band(.mid): Spec(period: 1 / 2.5, taps: [0], intensity: 0.6, sharpness: 0.6, buzz: 0)
        case .band(.far): Spec(period: 1, taps: [0], intensity: 0.4, sharpness: 0.5, buzz: 0)
        // "Scanning, nothing near": a single very soft tick every 3 s.
        case .band(.beyond): Spec(period: 3, taps: [0], intensity: 0.25, sharpness: 0.4, buzz: 0)
        // Clearly different from every distance band: soft, dull double tick every 2 s.
        case .noReading: Spec(period: 2, taps: [0, 0.15], intensity: 0.5, sharpness: 0.2, buzz: 0)
        // Silence after one long buzz.
        case .stopped: Spec(period: 0, taps: [], intensity: 0.7, sharpness: 0.3, buzz: 0.4)
        }
    }
}

/// Hysteresis band tracker (plan §5.7): a band change needs the estimate to pass the
/// boundary by `margin` for `confirmations` consecutive estimates.
public struct HapticMapper: Sendable {
    public var margin: Double = 0.10
    public var confirmations: Int = 2
    public private(set) var band: DistanceBand?
    private var pending: DistanceBand?
    private var pendingCount = 0

    public init(margin: Double = 0.10, confirmations: Int = 2) {
        self.margin = margin
        self.confirmations = confirmations
    }

    public mutating func reset() {
        band = nil
        pending = nil
        pendingCount = 0
    }

    /// Feed one accepted distance; returns the (possibly unchanged) band.
    @discardableResult
    public mutating func update(_ d: Double) -> DistanceBand {
        let raw = DistanceBand.of(d)
        guard let cur = band else {
            band = raw
            return raw
        }
        if raw == cur {
            pending = nil
            pendingCount = 0
            return cur
        }
        let passed: Bool
        if raw > cur, let up = cur.upper {
            passed = d >= up + margin
        } else if raw < cur, let low = cur.lower {
            passed = d <= low - margin
        } else {
            passed = false
        }
        guard passed else {
            pending = nil
            pendingCount = 0
            return cur
        }
        if pending == raw {
            pendingCount += 1
        } else {
            pending = raw
            pendingCount = 1
        }
        if pendingCount >= confirmations {
            band = raw
            pending = nil
            pendingCount = 0
        }
        return band!
    }
}

/// Smoothing + feedback state for a scan session (plan §5.7–5.8).
/// Median of the last 3 accepted estimates drives display and haptics; suppressed estimates
/// never enter the history; two suppressed in a row switch to "no reliable reading".
public struct ScanFeedback: Sendable {
    public struct Output: Equatable, Sendable {
        /// Smoothed distance to show, nil = "No reliable reading".
        public var displayDistance: Double?
        public var pattern: HapticPattern
        /// True when the pattern changed (announce / re-arm haptics).
        public var changed: Bool
    }

    public var historySize = 3
    private(set) var history: [Double] = []
    private var suppressedRun = 0
    private var mapper = HapticMapper()
    public private(set) var pattern: HapticPattern = .noReading

    public init() {}

    public mutating func start() {
        history = []
        suppressedRun = 0
        mapper.reset()
        pattern = .noReading
    }

    public mutating func stop() -> Output {
        let changed = pattern != .stopped
        pattern = .stopped
        history = []
        mapper.reset()
        return Output(displayDistance: nil, pattern: .stopped, changed: changed)
    }

    /// `distance` is the burst's accepted distance, or nil when suppressed.
    public mutating func update(_ distance: Double?) -> Output {
        let old = pattern
        if let d = distance {
            suppressedRun = 0
            history.append(d)
            if history.count > historySize { history.removeFirst(history.count - historySize) }
            let smoothed = PeakDetector.median(history)
            pattern = .band(mapper.update(smoothed))
            return Output(displayDistance: smoothed, pattern: pattern, changed: pattern != old)
        }
        suppressedRun += 1
        if suppressedRun >= 2 || history.isEmpty {
            history = []
            mapper.reset()
            pattern = .noReading
            return Output(displayDistance: nil, pattern: .noReading, changed: pattern != old)
        }
        // A single suppressed burst keeps the last smoothed reading.
        return Output(displayDistance: PeakDetector.median(history), pattern: pattern, changed: false)
    }
}
