import Accelerate
import Foundation

/// Kaiser-windowed sinc band-pass FIR (plan §5.2 step 2), equivalent to
/// scipy.signal.firwin(taps, [f0-m, f1+m], pass_zero=False, window=('kaiser', beta)).
public enum BandPassFilter {
    /// Modified Bessel function of the first kind, order 0 (power series).
    public static func besselI0(_ x: Double) -> Double {
        let y = (x / 2) * (x / 2)
        var term = 1.0
        var total = 1.0
        for k in 1..<60 {
            term *= y / Double(k * k)
            total += term
        }
        return total
    }

    static func sinc(_ x: Double) -> Double {
        x == 0 ? 1 : sin(.pi * x) / (.pi * x)
    }

    public static func taps(_ config: SignalConfig = .default) -> [Double] {
        let n = config.firTaps
        let nyq = config.fs / 2
        let lo = (min(config.f0, config.f1) - config.firMarginHz) / nyq
        let hi = min((max(config.f0, config.f1) + config.firMarginHz) / nyq, 0.999)
        let i0b = besselI0(config.kaiserBeta)
        var h = [Double](repeating: 0, count: n)
        let fc = 0.5 * (lo + hi)
        var gain = 0.0
        for i in 0..<n {
            let m = Double(i) - Double(n - 1) / 2
            let r = 2 * Double(i) / Double(n - 1) - 1
            let w = besselI0(config.kaiserBeta * (1 - r * r).squareRoot()) / i0b
            h[i] = (hi * sinc(hi * m) - lo * sinc(lo * m)) * w
            gain += h[i] * cos(.pi * m * fc)
        }
        return h.map { $0 / gain }
    }

    /// Causal FIR, output truncated to `x.count` (np.convolve(x, h)[:len(x)]).
    public static func filterCausal(_ x: [Double], _ h: [Double]) -> [Double] {
        let p = h.count
        guard !x.isEmpty, p > 0 else { return x }
        var padded = [Double](repeating: 0, count: p - 1)
        padded.append(contentsOf: x)
        return convolve(padded, h, outputCount: x.count)
    }

    /// Full convolution (np.convolve(x, h)), length x.count + h.count - 1.
    public static func convolveFull(_ x: [Double], _ h: [Double]) -> [Double] {
        let p = h.count
        let zeros = [Double](repeating: 0, count: p - 1)
        return convolve(zeros + x + zeros, h, outputCount: x.count + p - 1)
    }

    /// result[n] = sum_j signal[n + P - 1 - j] * h[j], signal has outputCount + P - 1 samples.
    private static func convolve(_ signal: [Double], _ h: [Double], outputCount: Int) -> [Double] {
        var out = [Double](repeating: 0, count: outputCount)
        let p = h.count
        signal.withUnsafeBufferPointer { s in
            h.withUnsafeBufferPointer { hp in
                out.withUnsafeMutableBufferPointer { o in
                    vDSP_convD(s.baseAddress!, 1, hp.baseAddress! + (p - 1), -1,
                               o.baseAddress!, 1, vDSP_Length(outputCount), vDSP_Length(p))
                }
            }
        }
        return out
    }
}
