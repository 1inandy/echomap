import Foundation

/// Fit `distance = scale * rawRange + offset` (plan R2, step C8). Mirrors `fit_calibration`.
public struct CalibrationFit: Codable, Equatable, Sendable {
    public var offset: Double
    public var scale: Double
    /// RMS residual over valid bursts (m).
    public var residual: Double
    /// Share of bursts with a valid estimate.
    public var reliability: Double
}

public enum Calibration {
    /// One known distance -> offset only (scale 1). Two or more -> least squares.
    /// `rawRanges[i]` is burst i's median raw range, nil if the burst failed.
    public static func fit(truth: [Double], rawRanges: [Double?]) throws -> CalibrationFit {
        precondition(truth.count == rawRanges.count)
        let pairs = zip(truth, rawRanges).compactMap { t, r in r.map { (t, $0) } }
        let reliability = truth.isEmpty ? 0 : Double(pairs.count) / Double(truth.count)
        guard !pairs.isEmpty else { throw EchoError.noValidBursts }
        let t = pairs.map(\.0), r = pairs.map(\.1)
        let distinct = Set(t.map { ($0 * 1e6).rounded() })
        let scale: Double, offset: Double
        if distinct.count < 2 {
            scale = 1
            offset = zip(t, r).map { $0 - $1 }.reduce(0, +) / Double(t.count)
        } else {
            let rm = r.reduce(0, +) / Double(r.count)
            let tm = t.reduce(0, +) / Double(t.count)
            let sxy = zip(r, t).map { ($0 - rm) * ($1 - tm) }.reduce(0, +)
            let sxx = r.map { ($0 - rm) * ($0 - rm) }.reduce(0, +)
            scale = sxy / sxx
            offset = tm - scale * rm
        }
        let res = zip(t, r).map { $0 - (scale * $1 + offset) }
        let rms = (res.map { $0 * $0 }.reduce(0, +) / Double(res.count)).squareRoot()
        return CalibrationFit(offset: offset, scale: scale, residual: rms, reliability: reliability)
    }
}

/// Saved per device + mic source (plan §7).
public struct CalibrationProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var deviceModel: String
    public var micSource: String
    public var polarPattern: String
    public var sampleRate: Double
    public var f0: Double
    public var f1: Double
    public var offsetM: Double
    public var scale: Double
    public var detectionK: Double
    /// Float32 interleaved (re, im), base64.
    public var leakageTemplate: String?
    public var leakageTemplatePre: Int?
    public var reliability: Double
    public var residualM: Double
    public var createdAt: Date

    public init(id: String = UUID().uuidString, deviceModel: String, micSource: String,
                polarPattern: String, sampleRate: Double, f0: Double, f1: Double,
                offsetM: Double, scale: Double, detectionK: Double,
                template: LeakageTemplate?, reliability: Double, residualM: Double,
                createdAt: Date = Date()) {
        self.id = id
        self.deviceModel = deviceModel
        self.micSource = micSource
        self.polarPattern = polarPattern
        self.sampleRate = sampleRate
        self.f0 = f0
        self.f1 = f1
        self.offsetM = offsetM
        self.scale = scale
        self.detectionK = detectionK
        leakageTemplate = template?.base64Float32
        leakageTemplatePre = template?.pre
        self.reliability = reliability
        self.residualM = residualM
        self.createdAt = createdAt
    }

    public var template: LeakageTemplate? {
        guard let s = leakageTemplate, let pre = leakageTemplatePre else { return nil }
        return LeakageTemplate(base64Float32: s, pre: pre)
    }

    /// Whether this profile was made for the given band.
    public func matches(_ config: SignalConfig) -> Bool {
        abs(f0 - config.f0) < 1 && abs(f1 - config.f1) < 1 && abs(sampleRate - config.fs) < 1
    }
}
