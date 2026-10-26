import Foundation

public struct ChirpResult: Codable, Equatable, Sendable {
    public var tauDirect: Double
    public var directPeak: Double
    public var floor: Double
    public var sigma: Double
    public var tauEcho: Double?
    public var echoPeak: Double?
    public var distance: Double?
    /// c * Δlag / 2 with no offset or scale (calibration input).
    public var rawRange: Double?
    public var snrDb: Double?
    public var promSigma: Double?

    public var isValid: Bool { distance != nil }
}

public struct BurstResult: Codable, Equatable, Sendable {
    public var chirps: [ChirpResult]
    public var n: Int
    public var valid: Int
    /// nil when suppressed.
    public var distance: Double?
    /// Median of valid chirps even when suppressed (diagnostics only, never shown as fact).
    public var medianDistance: Double?
    public var rawRange: Double?
    public var mad: Double?
    public var snrDb: Double?
    public var promSigma: Double?
    public var confidence: Confidence?
    public var category: ConfidenceCategory

    public var suppressed: Bool { category == .suppressed }
}

/// Per-chirp processing and burst aggregation (plan §5.2–5.5). Mirrors `pipeline.py`.
///
/// Holds FFT setup and the reference spectrum; not thread-safe — use from one queue.
public final class RangeEstimator: @unchecked Sendable {
    public static let snrCapDb = 120.0
    public static let promCap = 1e6

    public let config: SignalConfig
    public let taps: [Double]
    public let reference: [Double]
    private let fft: FFT
    private let refSpectrum: ComplexBuffer

    public init(config: SignalConfig = .default) {
        self.config = config
        taps = BandPassFilter.taps(config)
        reference = MatchedFilter.filteredReference(config)
        fft = FFT(n: MatchedFilter.nextPow2(2 * max(config.periodLength, reference.count)))
        refSpectrum = MatchedFilter.spectrum(reference, fft: fft)
    }

    public func lag(forDistance d: Double, offset: Double, scale: Double) -> Double {
        2 * (d - offset) / (scale * config.speedOfSound) * config.fs
    }

    public func distance(forLag dlag: Double, offset: Double, scale: Double) -> Double {
        scale * config.speedOfSound * dlag / (2 * config.fs) + offset
    }

    /// Band-pass -> analytic matched filter -> baseband.
    public func baseband(window: [Double]) -> ComplexBuffer {
        let xf = BandPassFilter.filterCausal(window, taps)
        let c: ComplexBuffer
        if window.count <= config.periodLength {
            c = MatchedFilter.analyticXcorr(xf, refSpectrum: refSpectrum, fft: fft)
        } else {
            c = MatchedFilter.analyticXcorr(xf, reference)
        }
        return MatchedFilter.baseband(c, config)
    }

    func noiseRegion(_ env: [Double], td: Double, offset: Double, scale: Double) -> ArraySlice<Double> {
        let P = env.count
        let a = Int((td + lag(forDistance: config.noiseLoM, offset: offset, scale: scale)).rounded(.up))
        let b = Int((td + lag(forDistance: config.noiseHiM, offset: offset, scale: scale)).rounded(.down))
        if b <= P - 1 { return env[a...b] }
        let preEnd = Int(td.rounded(.down)) - LeakageTemplate.lengths(config).pre
        if preEnd >= 64 { return env[0..<preEnd] }
        let n = b - a + 1
        return env[(P - n)..<P]
    }

    public func processChirp(_ window: [Double], template: LeakageTemplate?,
                             offset: Double? = nil, scale: Double = 1) -> ChirpResult {
        let offset = offset ?? config.defaultOffsetM
        var b = baseband(window: window)
        var env = b.magnitude()
        let (td, directPeak) = PeakDetector.directPath(env, config)
        if let template {
            b = template.subtract(from: b, directTau: td, config: config)
            env = b.magnitude()
        }
        let region = noiseRegion(env, td: td, offset: offset, scale: scale)
        let floor = PeakDetector.median(region)
        let sigma = PeakDetector.madScale * PeakDetector.mad(region)
        var res = ChirpResult(tauDirect: td, directPeak: directPeak, floor: floor, sigma: sigma)

        let P = env.count
        let lo = max(Int((td + lag(forDistance: config.blankingM, offset: offset, scale: scale)).rounded(.up)), 1)
        let hi = min(Int((td + lag(forDistance: config.maxRangeM, offset: offset, scale: scale)).rounded(.down)), P - 2)
        guard hi >= lo else { return res }
        let thr = max(floor + config.detectionK * sigma, directPeak * pow(10, config.sidelobeGuardDb / 20))
        let minProm = config.minProminenceSigma * sigma
        let width = Int((config.clusterPulseWidths * config.fs / config.bandwidth).rounded(.toNearestOrEven))

        func isPeak(_ i: Int) -> Bool { env[i] > env[i - 1] && env[i] >= env[i + 1] && env[i] > thr }

        var first: Int?
        for i in lo...hi where isPeak(i) && PeakDetector.prominence(env, i, lo: lo, hi: hi) >= minProm {
            first = i
            break
        }
        guard let first else { return res }

        // Climb to the dominant peak of the cluster (an echo's leading sidelobes come first).
        var best = first
        var moved = true
        while moved {
            moved = false
            let end = min(best + width, hi)
            if best + 1 <= end {
                for i in (best + 1)...end where isPeak(i) && env[i] > env[best] {
                    best = i
                    moved = true
                    break
                }
            }
        }

        let te = PeakDetector.parabolic(env, best)
        let dlag = te - td
        res.tauEcho = te
        res.echoPeak = env[best]
        res.rawRange = config.speedOfSound * dlag / (2 * config.fs)
        res.distance = distance(forLag: dlag, offset: offset, scale: scale)
        res.snrDb = floor <= 0 ? Self.snrCapDb : min(Self.snrCapDb, 20 * log10(env[best] / floor))
        let prom = PeakDetector.prominence(env, best, lo: lo, hi: hi)
        res.promSigma = sigma <= 0 ? Self.promCap : min(Self.promCap, prom / sigma)
        return res
    }

    public func processBurst(_ recording: [Double], template: LeakageTemplate?,
                             offset: Double? = nil, scale: Double = 1) -> BurstResult {
        let p = config.periodLength
        var chirps: [ChirpResult] = []
        for i in 0..<config.nChirps {
            guard (i + 1) * p <= recording.count else { break }
            chirps.append(processChirp(Array(recording[(i * p)..<((i + 1) * p)]),
                                       template: template, offset: offset, scale: scale))
        }
        return aggregate(chirps)
    }

    public func processBurst(_ recording: [Float], template: LeakageTemplate?,
                             offset: Double? = nil, scale: Double = 1) -> BurstResult {
        processBurst(recording.map(Double.init), template: template, offset: offset, scale: scale)
    }

    public func aggregate(_ chirps: [ChirpResult]) -> BurstResult {
        let n = config.nChirps
        let good = chirps.filter(\.isValid)
        guard !good.isEmpty else {
            return BurstResult(chirps: chirps, n: n, valid: 0, category: .suppressed)
        }
        let ds = good.map { $0.distance! }
        let dMed = PeakDetector.median(ds)
        let dMad = PeakDetector.mad(ds)
        let raw = PeakDetector.median(good.map { $0.rawRange! })
        let snr = PeakDetector.median(good.map { $0.snrDb! })
        let prom = PeakDetector.median(good.map { $0.promSigma! })
        let conf = ConfidenceModel.confidence(snrDb: snr, madM: dMad, valid: good.count, n: n, promSigma: prom)
        let cat: ConfidenceCategory = good.count >= config.minValidChirps
            ? ConfidenceModel.categorize(conf.value, config) : .suppressed
        return BurstResult(chirps: chirps, n: n, valid: good.count,
                           distance: cat == .suppressed ? nil : dMed, medianDistance: dMed,
                           rawRange: raw, mad: dMad, snrDb: snr, promSigma: prom,
                           confidence: conf, category: cat)
    }
}

extension BurstResult {
    init(chirps: [ChirpResult], n: Int, valid: Int, category: ConfidenceCategory) {
        self.init(chirps: chirps, n: n, valid: valid, distance: nil, medianDistance: nil,
                  rawRange: nil, mad: nil, snrDb: nil, promSigma: nil, confidence: nil,
                  category: category)
    }
}
