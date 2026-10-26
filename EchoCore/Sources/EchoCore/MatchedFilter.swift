import Accelerate
import Foundation

/// Split-complex sequence.
public struct ComplexBuffer: Equatable, Sendable {
    public var re: [Double]
    public var im: [Double]

    public init(re: [Double], im: [Double]) {
        precondition(re.count == im.count)
        self.re = re
        self.im = im
    }

    public init(count: Int) {
        re = [Double](repeating: 0, count: count)
        im = [Double](repeating: 0, count: count)
    }

    public var count: Int { re.count }

    public func magnitude() -> [Double] {
        var out = [Double](repeating: 0, count: count)
        for i in 0..<count { out[i] = (re[i] * re[i] + im[i] * im[i]).squareRoot() }
        return out
    }

    public func slice(_ r: Range<Int>) -> ComplexBuffer {
        ComplexBuffer(re: Array(re[r]), im: Array(im[r]))
    }
}

/// Radix-2 complex FFT (vDSP), cached per size.
final class FFT {
    let n: Int
    let log2n: vDSP_Length
    private let setup: FFTSetupD

    init(n: Int) {
        precondition(n > 0 && n & (n - 1) == 0, "FFT size must be a power of two")
        self.n = n
        log2n = vDSP_Length(n.trailingZeroBitCount)
        setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2))!
    }

    deinit { vDSP_destroy_fftsetupD(setup) }

    /// In place. Forward is unscaled; inverse is scaled by 1/n (numpy convention).
    func transform(_ z: inout ComplexBuffer, inverse: Bool) {
        precondition(z.count == n)
        z.re.withUnsafeMutableBufferPointer { rp in
            z.im.withUnsafeMutableBufferPointer { ip in
                var sc = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zipD(setup, &sc, 1, log2n,
                              FFTDirection(inverse ? kFFTDirection_Inverse : kFFTDirection_Forward))
            }
        }
        if inverse {
            var s = 1.0 / Double(n)
            z.re.withUnsafeMutableBufferPointer { vDSP_vsmulD($0.baseAddress!, 1, &s, $0.baseAddress!, 1, vDSP_Length(n)) }
            z.im.withUnsafeMutableBufferPointer { vDSP_vsmulD($0.baseAddress!, 1, &s, $0.baseAddress!, 1, vDSP_Length(n)) }
        }
    }
}

/// Analytic cross-correlation and baseband envelope (plan §5.2 step 3).
public enum MatchedFilter {
    public static func nextPow2(_ n: Int) -> Int {
        var p = 1
        while p < n { p <<= 1 }
        return p
    }

    /// The transmitted chirp through the same band-pass, full convolution, so the filter's
    /// group delay cancels in the lag.
    public static func filteredReference(_ config: SignalConfig = .default) -> [Double] {
        BandPassFilter.convolveFull(ChirpGenerator.chirp(config), BandPassFilter.taps(config))
    }

    /// c[k] = sum_n x[n+k] ref[n] (+ j Hilbert) for k in 0..<x.count.
    static func analyticXcorr(_ x: [Double], refSpectrum: ComplexBuffer, fft: FFT) -> ComplexBuffer {
        let n = fft.n
        var X = ComplexBuffer(count: n)
        for i in 0..<min(x.count, n) { X.re[i] = x[i] }
        fft.transform(&X, inverse: false)
        // X * conj(R), then keep positive frequencies (x2), DC and Nyquist as is.
        for i in 0..<n {
            let a = X.re[i], b = X.im[i], c = refSpectrum.re[i], d = refSpectrum.im[i]
            var r = a * c + b * d
            var m = b * c - a * d
            if i > 0 && i < n / 2 { r *= 2; m *= 2 } else if i > n / 2 { r = 0; m = 0 }
            X.re[i] = r
            X.im[i] = m
        }
        fft.transform(&X, inverse: true)
        return X.slice(0..<x.count)
    }

    public static func analyticXcorr(_ x: [Double], _ ref: [Double]) -> ComplexBuffer {
        let fft = FFT(n: nextPow2(2 * max(x.count, ref.count)))
        return analyticXcorr(x, refSpectrum: spectrum(ref, fft: fft), fft: fft)
    }

    static func spectrum(_ x: [Double], fft: FFT) -> ComplexBuffer {
        var R = ComplexBuffer(count: fft.n)
        for i in 0..<min(x.count, fft.n) { R.re[i] = x[i] }
        fft.transform(&R, inverse: false)
        return R
    }

    /// Shift down by the chirp centre frequency; |baseband| is the envelope.
    public static func baseband(_ c: ComplexBuffer, _ config: SignalConfig) -> ComplexBuffer {
        var out = c
        let w = -2 * Double.pi * config.centerFrequency / config.fs
        for k in 0..<c.count {
            let cr = cos(w * Double(k)), ci = sin(w * Double(k))
            out.re[k] = c.re[k] * cr - c.im[k] * ci
            out.im[k] = c.re[k] * ci + c.im[k] * cr
        }
        return out
    }

    /// Linear interpolation at fractional positions; 0 outside.
    public static func interpolate(_ z: ComplexBuffer, at pos: [Double]) -> ComplexBuffer {
        var out = ComplexBuffer(count: pos.count)
        let n = z.count
        for (j, p) in pos.enumerated() {
            let fl = p.rounded(.down)
            let i0 = Int(fl)
            let f = p - fl
            if i0 >= 0 && i0 + 1 < n {
                out.re[j] = z.re[i0] * (1 - f) + z.re[i0 + 1] * f
                out.im[j] = z.im[i0] * (1 - f) + z.im[i0 + 1] * f
            } else if i0 == n - 1 && f == 0 {
                out.re[j] = z.re[n - 1]
                out.im[j] = z.im[n - 1]
            }
        }
        return out
    }
}
