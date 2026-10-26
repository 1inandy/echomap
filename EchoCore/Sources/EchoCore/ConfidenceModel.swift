import Foundation

/// Plan §5.4: each component in [0, 1], combined by geometric mean.
public struct Confidence: Codable, Equatable, Sendable {
    public var snr: Double
    public var consistency: Double
    public var detection: Double
    public var prominence: Double

    public init(snr: Double, consistency: Double, detection: Double, prominence: Double) {
        self.snr = snr
        self.consistency = consistency
        self.detection = detection
        self.prominence = prominence
    }

    public var value: Double {
        let p = snr * consistency * detection * prominence
        return p > 0 ? pow(p, 0.25) : 0
    }
}

public enum ConfidenceCategory: String, Codable, Sendable {
    case high, medium, suppressed

    /// The word shown and spoken to the user.
    public var label: String {
        switch self {
        case .high: "High"
        case .medium: "Medium"
        case .suppressed: "Low"
        }
    }
}

public enum ConfidenceModel {
    static func clamp01(_ x: Double) -> Double { x < 0 ? 0 : (x > 1 ? 1 : x) }

    public static func confidence(snrDb: Double, madM: Double, valid: Int, n: Int,
                                  promSigma: Double) -> Confidence {
        Confidence(snr: clamp01((snrDb - 6) / 14),
                   consistency: exp(-madM / 0.05),
                   detection: n > 0 ? Double(valid) / Double(n) : 0,
                   prominence: clamp01((promSigma - 3) / 9))
    }

    public static func categorize(_ value: Double, _ config: SignalConfig) -> ConfidenceCategory {
        if value >= config.highThreshold { return .high }
        if value >= config.mediumThreshold { return .medium }
        return .suppressed
    }
}
