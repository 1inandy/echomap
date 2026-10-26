import Foundation

/// Coverage and accuracy, reported separately (plan R9). Mirrors `stats.py`.
public struct TrialSummary: Equatable, Sendable {
    public var n: Int
    public var accepted: Int
    public var coverage: Double
    public var medianAbs: Double?
    public var p90Abs: Double?
    public var meanSigned: Double?
    public var sdSigned: Double?
    /// Share of accepted trials with |err| > 0.30 m.
    public var wronglyAccepted: Double?
}

public enum Stats {
    public static let wrongM = 0.30

    /// numpy.percentile with linear interpolation.
    public static func percentile(_ x: [Double], _ q: Double) -> Double {
        precondition(!x.isEmpty)
        let s = x.sorted()
        let pos = q / 100 * Double(s.count - 1)
        let lo = Int(pos.rounded(.down)), hi = Int(pos.rounded(.up))
        return s[lo] + (s[hi] - s[lo]) * (pos - Double(lo))
    }

    public static func summarize(_ trials: [TrialRecord]) -> TrialSummary {
        let gt = trials.filter { $0.actualDistanceM != nil }
        let acc = gt.filter { !$0.suppressed && $0.estimatedDistanceM != nil }
        let n = gt.count
        guard !acc.isEmpty else {
            return TrialSummary(n: n, accepted: 0, coverage: 0)
        }
        let err = acc.map { $0.signedErrorM! }
        let a = err.map(abs)
        let mean = err.reduce(0, +) / Double(err.count)
        let sd = err.count > 1
            ? (err.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(err.count - 1)).squareRoot() : 0
        return TrialSummary(n: n, accepted: acc.count, coverage: Double(acc.count) / Double(n),
                            medianAbs: PeakDetector.median(a), p90Abs: percentile(a, 90),
                            meanSigned: mean, sdSigned: sd,
                            wronglyAccepted: Double(a.filter { $0 > wrongM }.count) / Double(a.count))
    }

    /// Per ground-truth distance, sorted ascending.
    public static func perDistance(_ trials: [TrialRecord]) -> [(distance: Double, summary: TrialSummary)] {
        let groups = Dictionary(grouping: trials.filter { $0.actualDistanceM != nil }) {
            ($0.actualDistanceM! * 1000).rounded() / 1000
        }
        return groups.keys.sorted().map { ($0, summarize(groups[$0]!)) }
    }
}
