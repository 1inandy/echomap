import Foundation

/// Average baseband correlation around the direct path, phase-normalised (plan §5.2 step 5).
/// Index `pre` is the direct-path peak.
public struct LeakageTemplate: Codable, Equatable, Sendable {
    public var re: [Double]
    public var im: [Double]
    public var pre: Int

    public init(re: [Double], im: [Double], pre: Int) {
        self.re = re
        self.im = im
        self.pre = pre
    }

    public var count: Int { re.count }
    var buffer: ComplexBuffer { ComplexBuffer(re: re, im: im) }

    static func lengths(_ c: SignalConfig) -> (pre: Int, post: Int, taper: Int) {
        (c.samples(ms: c.templatePreMs), c.samples(ms: c.templatePostMs), c.samples(ms: c.templateTaperMs))
    }

    static func applyTaper(_ z: inout ComplexBuffer, taper: Int) {
        guard taper > 0 else { return }
        let n = z.count
        for k in 0..<taper {
            let g = 0.5 * (1 + cos(.pi * Double(k + 1) / Double(taper)))
            z.re[n - taper + k] *= g
            z.im[n - taper + k] *= g
        }
    }

    /// Build from an open-space capture (nothing within ~1 m): every full period is a chirp.
    public static func build(from recording: [Double], config: SignalConfig) throws -> LeakageTemplate {
        let (pre, post, taper) = lengths(config)
        let length = pre + post
        let est = RangeEstimator(config: config)
        let p = config.periodLength
        var acc = ComplexBuffer(count: length)
        var used = 0
        var i = 0
        while (i + 1) * p <= recording.count {
            let b = est.baseband(window: Array(recording[(i * p)..<((i + 1) * p)]))
            let env = b.magnitude()
            let td = PeakDetector.directPath(env, config).tau
            let seg = MatchedFilter.interpolate(b, at: (0..<length).map { td - Double(pre) + Double($0) })
            let ph = MatchedFilter.interpolate(b, at: [td])
            let mag = (ph.re[0] * ph.re[0] + ph.im[0] * ph.im[0]).squareRoot()
            i += 1
            if mag == 0 { continue }
            // seg * conj(ph) / |ph|
            let cr = ph.re[0] / mag, ci = -ph.im[0] / mag
            for k in 0..<length {
                acc.re[k] += seg.re[k] * cr - seg.im[k] * ci
                acc.im[k] += seg.re[k] * ci + seg.im[k] * cr
            }
            used += 1
        }
        guard used > 0 else { throw EchoError.noUsableChirps }
        for k in 0..<length {
            acc.re[k] /= Double(used)
            acc.im[k] /= Double(used)
        }
        applyTaper(&acc, taper: taper)
        return LeakageTemplate(re: acc.re, im: acc.im, pre: pre)
    }

    /// Ideal flat-response direct path: the reference's own baseband autocorrelation over its
    /// whole support. Used until a calibrated template exists.
    public static func ideal(_ config: SignalConfig) -> LeakageTemplate {
        let (pre, _, taper) = lengths(config)
        let ref = MatchedFilter.filteredReference(config)
        var x = [Double](repeating: 0, count: config.periodLength)
        let lag0 = pre + 1
        for j in 0..<ref.count { x[lag0 + j] = ref[j] }
        let b = MatchedFilter.baseband(MatchedFilter.analyticXcorr(x, ref), config)
        let length = pre + ref.count + taper
        var seg = b.slice((lag0 - pre)..<(lag0 - pre + length))
        let mag = (b.re[lag0] * b.re[lag0] + b.im[lag0] * b.im[lag0]).squareRoot()
        let cr = b.re[lag0] / mag, ci = -b.im[lag0] / mag
        for k in 0..<length {
            let r = seg.re[k], m = seg.im[k]
            seg.re[k] = r * cr - m * ci
            seg.im[k] = r * ci + m * cr
        }
        applyTaper(&seg, taper: taper)
        return LeakageTemplate(re: seg.re, im: seg.im, pre: pre)
    }

    /// Align to `td`, least-squares complex scale over td ± fit window, subtract.
    public func subtract(from b: ComplexBuffer, directTau td: Double, config: SignalConfig) -> ComplexBuffer {
        let L = count
        let start = td - Double(pre)
        let k0 = max(Int(start.rounded(.up)), 0)
        let k1 = min(Int((start + Double(L - 1)).rounded(.down)), b.count - 1)
        guard k1 >= k0 else { return b }
        let ks = Array(k0...k1)
        let t = MatchedFilter.interpolate(buffer, at: ks.map { Double($0) - start })
        let fit = config.samples(ms: config.templateFitMs)
        let c = Int(td.rounded(.toNearestOrEven))
        var den = 0.0, nr = 0.0, ni = 0.0
        for (j, k) in ks.enumerated() where k >= c - fit && k <= c + fit {
            let tr = t.re[j], ti = t.im[j], br = b.re[k], bi = b.im[k]
            den += tr * tr + ti * ti
            // conj(t) * b
            nr += tr * br + ti * bi
            ni += tr * bi - ti * br
        }
        guard den > 0 else { return b }
        let ar = nr / den, ai = ni / den
        var out = b
        for (j, k) in ks.enumerated() {
            out.re[k] -= ar * t.re[j] - ai * t.im[j]
            out.im[k] -= ar * t.im[j] + ai * t.re[j]
        }
        return out
    }

    /// Float32 interleaved (re, im) blob, base64 — the CalibrationProfile storage format.
    public var base64Float32: String {
        var f = [Float]()
        f.reserveCapacity(2 * count)
        for k in 0..<count { f.append(Float(re[k])); f.append(Float(im[k])) }
        return f.withUnsafeBufferPointer { Data(buffer: $0) }.base64EncodedString()
    }

    public init?(base64Float32 s: String, pre: Int) {
        guard let d = Data(base64Encoded: s), d.count % 8 == 0 else { return nil }
        let f: [Float] = d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        re = stride(from: 0, to: f.count, by: 2).map { Double(f[$0]) }
        im = stride(from: 1, to: f.count, by: 2).map { Double(f[$0]) }
        self.pre = pre
    }
}

public enum EchoError: Error, Equatable {
    case noUsableChirps
    case noValidBursts
    case invalidInput(String)
}
