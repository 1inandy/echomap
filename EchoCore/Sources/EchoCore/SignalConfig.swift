import Foundation

/// Every tunable of the ranging pipeline (ONE_SHOT_PLAN.md §5).
/// Must match `lab/echolab/signal.py` field for field.
public struct SignalConfig: Codable, Equatable, Hashable, Sendable {
    public static let algoVersion = "0.1.0"

    public var fs: Double = 48_000
    public var f0: Double = 18_000
    public var f1: Double = 20_000
    public var chirpMs: Double = 10
    public var tukeyAlpha: Double = 0.5
    public var amplitude: Double = 0.5
    public var nChirps: Int = 5
    public var periodMs: Double = 100

    // Band-pass FIR
    public var firTaps: Int = 129
    public var kaiserBeta: Double = 8
    public var firMarginHz: Double = 500

    // Detection
    public var directSearchMs: Double = 60
    public var blankingM: Double = 0.40
    public var maxRangeM: Double = 3.00
    public var noiseLoM: Double = 4.0
    public var noiseHiM: Double = 6.0
    public var detectionK: Double = 6.0
    public var minProminenceSigma: Double = 3.0
    /// A peak must also exceed this level relative to the direct-path peak.
    public var sidelobeGuardDb: Double = -70
    /// Climb window in pulse widths (fs/B samples): from the first detection, move to any
    /// higher peak within this window, repeatedly. Covers an echo's own leading sidelobes.
    public var clusterPulseWidths: Double = 3.0

    // Leakage template (relative to the direct peak)
    public var templatePreMs: Double = 1.0
    /// Covers leakage ringing; stays short of a floor echo (~1.1 m) in an open-space capture.
    public var templatePostMs: Double = 5.0
    public var templateTaperMs: Double = 0.5
    public var templateFitMs: Double = 1.0

    // Geometry / physics
    public var temperatureC: Double = 20
    public var speakerMicSeparationM: Double = 0.14

    // Aggregation / confidence
    public var minValidChirps: Int = 3
    public var highThreshold: Double = 0.75
    public var mediumThreshold: Double = 0.50

    public init() {}

    public static let `default` = SignalConfig()

    /// Audible development band, same structure.
    public static var audibleDev: SignalConfig {
        var c = SignalConfig()
        c.f0 = 14_000
        c.f1 = 17_000
        return c
    }

    public var chirpLength: Int { Int((chirpMs * 1e-3 * fs).rounded(.toNearestOrEven)) }
    public var periodLength: Int { Int((periodMs * 1e-3 * fs).rounded(.toNearestOrEven)) }
    public var centerFrequency: Double { 0.5 * (f0 + f1) }
    public var bandwidth: Double { abs(f1 - f0) }
    public var speedOfSound: Double { SignalConfig.speedOfSound(temperatureC: temperatureC) }
    public var defaultOffsetM: Double { 0.5 * speakerMicSeparationM }

    public static func speedOfSound(temperatureC: Double) -> Double {
        331.3 + 0.606 * temperatureC
    }

    func samples(ms: Double) -> Int { Int((ms * 1e-3 * fs).rounded(.toNearestOrEven)) }
}

extension SignalConfig {
    /// Snake-case JSON, the format Python writes and reads.
    public static func decode(json data: Data) throws -> SignalConfig {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(SignalConfig.self, from: data)
    }

    public func encodeJSON() throws -> Data {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys]
        return try e.encode(self)
    }

    // Missing keys fall back to defaults, so older sidecars / profiles still decode.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ cur: T) throws -> T { try c.decodeIfPresent(T.self, forKey: k) ?? cur }
        fs = try v(.fs, fs); f0 = try v(.f0, f0); f1 = try v(.f1, f1)
        chirpMs = try v(.chirpMs, chirpMs); tukeyAlpha = try v(.tukeyAlpha, tukeyAlpha)
        amplitude = try v(.amplitude, amplitude); nChirps = try v(.nChirps, nChirps)
        periodMs = try v(.periodMs, periodMs); firTaps = try v(.firTaps, firTaps)
        kaiserBeta = try v(.kaiserBeta, kaiserBeta); firMarginHz = try v(.firMarginHz, firMarginHz)
        directSearchMs = try v(.directSearchMs, directSearchMs); blankingM = try v(.blankingM, blankingM)
        maxRangeM = try v(.maxRangeM, maxRangeM); noiseLoM = try v(.noiseLoM, noiseLoM)
        noiseHiM = try v(.noiseHiM, noiseHiM); detectionK = try v(.detectionK, detectionK)
        minProminenceSigma = try v(.minProminenceSigma, minProminenceSigma)
        sidelobeGuardDb = try v(.sidelobeGuardDb, sidelobeGuardDb)
        clusterPulseWidths = try v(.clusterPulseWidths, clusterPulseWidths)
        templatePreMs = try v(.templatePreMs, templatePreMs)
        templatePostMs = try v(.templatePostMs, templatePostMs)
        templateTaperMs = try v(.templateTaperMs, templateTaperMs)
        templateFitMs = try v(.templateFitMs, templateFitMs)
        temperatureC = try v(.temperatureC, temperatureC)
        speakerMicSeparationM = try v(.speakerMicSeparationM, speakerMicSeparationM)
        minValidChirps = try v(.minValidChirps, minValidChirps)
        highThreshold = try v(.highThreshold, highThreshold)
        mediumThreshold = try v(.mediumThreshold, mediumThreshold)
    }
}
