import Foundation

/// Tukey-windowed linear chirp and bursts (plan §5.1). Mirrors `signal.py`.
public enum ChirpGenerator {
    /// Tukey window, identical to scipy.signal.windows.tukey(n, alpha, sym=True).
    public static func tukey(_ n: Int, alpha: Double) -> [Double] {
        if n == 1 { return [1] }
        if alpha <= 0 { return [Double](repeating: 1, count: n) }
        var w = [Double](repeating: 1, count: n)
        let a2 = alpha / 2
        for i in 0..<n {
            let x = Double(i) / Double(n - 1)
            if x < a2 {
                w[i] = 0.5 * (1 + cos(.pi * (2 * x / alpha - 1)))
            } else if x > 1 - a2 {
                w[i] = 0.5 * (1 + cos(.pi * (2 * x / alpha - 2 / alpha + 1)))
            }
        }
        return w
    }

    /// The transmitted chirp, `config.chirpLength` samples.
    public static func chirp(_ config: SignalConfig = .default) -> [Double] {
        let n = config.chirpLength
        let T = Double(n) / config.fs
        let k = (config.f1 - config.f0) / T
        let w = tukey(n, alpha: config.tukeyAlpha)
        return (0..<n).map { i in
            let t = Double(i) / config.fs
            return config.amplitude * w[i] * sin(2 * .pi * (config.f0 * t + 0.5 * k * t * t))
        }
    }

    /// `nChirps` chirps, one at the start of each period.
    public static func burst(_ config: SignalConfig = .default) -> [Float] {
        let p = config.periodLength
        var out = [Float](repeating: 0, count: config.nChirps * p)
        let c = chirp(config)
        for i in 0..<config.nChirps {
            for j in 0..<c.count { out[i * p + j] = Float(c[j]) }
        }
        return out
    }
}
