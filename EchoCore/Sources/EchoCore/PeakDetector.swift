import Foundation

/// Robust statistics, sub-sample peaks, prominence and the direct-path locator.
public enum PeakDetector {
    public static let madScale = 1.4826

    /// numpy.median (mean of the two middle values for even counts).
    public static func median<C: Collection>(_ x: C) -> Double where C.Element == Double {
        precondition(!x.isEmpty)
        let s = x.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : 0.5 * (s[n / 2 - 1] + s[n / 2])
    }

    public static func mad<C: Collection>(_ x: C) -> Double where C.Element == Double {
        let m = median(x)
        return median(x.map { abs($0 - m) })
    }

    /// Parabola through y[i-1], y[i], y[i+1].
    public static func parabolic(_ y: [Double], _ i: Int) -> Double {
        if i <= 0 || i >= y.count - 1 { return Double(i) }
        let a = y[i - 1], b = y[i], c = y[i + 1]
        let den = a - 2 * b + c
        if den == 0 { return Double(i) }
        return Double(i) + 0.5 * (a - c) / den
    }

    /// Topographic prominence of env[i], search limited to lo...hi.
    public static func prominence(_ env: [Double], _ i: Int, lo: Int, hi: Int) -> Double {
        let p = env[i]
        var leftMin = p
        var j = i - 1
        while j >= lo && env[j] <= p { leftMin = min(leftMin, env[j]); j -= 1 }
        var rightMin = p
        j = i + 1
        while j <= hi && env[j] <= p { rightMin = min(rightMin, env[j]); j += 1 }
        return p - max(leftMin, rightMin)
    }

    /// Global envelope maximum in the first `directSearchMs` (plan §5.2 step 4).
    public static func directPath(_ env: [Double], _ config: SignalConfig) -> (tau: Double, peak: Double) {
        let n = min(env.count, config.samples(ms: config.directSearchMs))
        var best = 0
        for k in 1..<n where env[k] > env[best] { best = k }
        return (parabolic(env, best), env[best])
    }
}
