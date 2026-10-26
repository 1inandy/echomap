import Foundation

/// One measurement, as stored, exported and analysed (plan §7). Never contains audio.
public struct TrialRecord: Codable, Equatable, Identifiable, Sendable {
    public enum Mode: String, Codable, Sendable { case scan, experiment, calibration }

    public var trialId: String
    public var sessionId: String
    public var timestamp: Date
    public var appVersion: String
    public var algoVersion: String
    public var deviceModel: String
    public var mode: Mode
    public var environment: String?
    public var surfaceMaterial: String?
    public var holdOrientation: String?
    public var micSource: String?
    public var polarPattern: String?
    public var pitchDeg: Double?
    public var rollDeg: Double?
    public var temperatureC: Double?
    public var freqStartHz: Double
    public var freqEndHz: Double
    public var chirpMs: Double
    public var nChirps: Int
    public var periodMs: Double
    public var actualDistanceM: Double?
    public var estimatedDistanceM: Double?
    public var suppressed: Bool
    public var confidence: Double?
    public var confSnr: Double?
    public var confConsistency: Double?
    public var confDetection: Double?
    public var confProminence: Double?
    public var snrDb: Double?
    public var validChirps: Int?
    public var calibrationId: String?
    public var notes: String?

    public var id: String { trialId }

    public var signedErrorM: Double? {
        guard let a = actualDistanceM, let e = estimatedDistanceM else { return nil }
        return e - a
    }
    public var absoluteErrorM: Double? { signedErrorM.map(abs) }
    public var percentError: Double? {
        guard let a = actualDistanceM, a != 0, let err = absoluteErrorM else { return nil }
        return 100 * err / a
    }

    public init(trialId: String = UUID().uuidString, sessionId: String, timestamp: Date = Date(),
                appVersion: String, deviceModel: String, mode: Mode, config: SignalConfig,
                result: BurstResult?, actualDistanceM: Double? = nil, environment: String? = nil,
                surfaceMaterial: String? = nil, holdOrientation: String? = nil,
                micSource: String? = nil, polarPattern: String? = nil, pitchDeg: Double? = nil,
                rollDeg: Double? = nil, calibrationId: String? = nil, notes: String? = nil) {
        self.trialId = trialId
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.appVersion = appVersion
        algoVersion = SignalConfig.algoVersion
        self.deviceModel = deviceModel
        self.mode = mode
        self.environment = environment
        self.surfaceMaterial = surfaceMaterial
        self.holdOrientation = holdOrientation
        self.micSource = micSource
        self.polarPattern = polarPattern
        self.pitchDeg = pitchDeg
        self.rollDeg = rollDeg
        temperatureC = config.temperatureC
        freqStartHz = config.f0
        freqEndHz = config.f1
        chirpMs = config.chirpMs
        nChirps = config.nChirps
        periodMs = config.periodMs
        self.actualDistanceM = actualDistanceM
        estimatedDistanceM = result?.distance
        suppressed = result?.suppressed ?? true
        confidence = result?.confidence?.value
        confSnr = result?.confidence?.snr
        confConsistency = result?.confidence?.consistency
        confDetection = result?.confidence?.detection
        confProminence = result?.confidence?.prominence
        snrDb = result?.snrDb
        validChirps = result?.valid
        self.calibrationId = calibrationId
        self.notes = notes
    }
}

/// RFC 4180 CSV with the exact §7 header. Line terminator CRLF.
public enum TrialCSV {
    public static let columns = [
        "trial_id", "session_id", "timestamp_iso", "app_version", "algo_version", "device_model",
        "mode", "environment", "surface_material", "hold_orientation",
        "mic_source", "polar_pattern", "pitch_deg", "roll_deg", "temperature_c",
        "freq_start_hz", "freq_end_hz", "chirp_ms", "n_chirps", "period_ms",
        "actual_distance_m", "estimated_distance_m", "signed_error_m", "absolute_error_m",
        "percent_error",
        "suppressed", "confidence", "conf_snr", "conf_consistency", "conf_detection",
        "conf_prominence",
        "snr_db", "valid_chirps", "calibration_id", "notes",
    ]

    public static func escape(_ s: String) -> String {
        if s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    static func num(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "" }
        return String(v)
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    public static func row(_ t: TrialRecord) -> [String] {
        [t.trialId, t.sessionId, iso(t.timestamp), t.appVersion, t.algoVersion, t.deviceModel,
         t.mode.rawValue, t.environment ?? "", t.surfaceMaterial ?? "", t.holdOrientation ?? "",
         t.micSource ?? "", t.polarPattern ?? "", num(t.pitchDeg), num(t.rollDeg), num(t.temperatureC),
         num(t.freqStartHz), num(t.freqEndHz), num(t.chirpMs), String(t.nChirps), num(t.periodMs),
         num(t.actualDistanceM), num(t.estimatedDistanceM), num(t.signedErrorM),
         num(t.absoluteErrorM), num(t.percentError),
         t.suppressed ? "true" : "false", num(t.confidence), num(t.confSnr),
         num(t.confConsistency), num(t.confDetection), num(t.confProminence),
         num(t.snrDb), t.validChirps.map(String.init) ?? "", t.calibrationId ?? "", t.notes ?? ""]
    }

    public static func encode(_ trials: [TrialRecord]) -> String {
        var out = columns.joined(separator: ",") + "\r\n"
        for t in trials {
            out += row(t).map(escape).joined(separator: ",") + "\r\n"
        }
        return out
    }
}
