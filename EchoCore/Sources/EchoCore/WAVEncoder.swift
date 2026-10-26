import Foundation

/// Mono 32-bit float WAV (IEEE, format 3) and the Capture Lab JSON sidecar.
public enum WAVEncoder {
    public static func encode(_ samples: [Float], sampleRate: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let dataBytes = UInt32(samples.count * 4)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(3); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 4)); u16(4); u16(32)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        for s in samples { u32(s.bitPattern) }
        return d
    }
}

/// Written next to every Capture Lab WAV; read by `lab/echolab/io.py:read_capture`.
public struct CaptureMetadata: Codable, Equatable, Sendable {
    public var config: SignalConfig
    public var label: String
    public var deviceModel: String
    public var appVersion: String
    public var algoVersion: String = SignalConfig.algoVersion
    public var timestampIso: String
    public var micSource: String
    public var polarPattern: String
    public var holdOrientation: String
    public var pitchDeg: Double?
    public var rollDeg: Double?
    public var temperatureC: Double
    public var actualSampleRate: Double
    public var ioBufferDuration: Double?
    public var notes: String?

    public init(config: SignalConfig, label: String, deviceModel: String, appVersion: String,
                timestamp: Date = Date(), micSource: String, polarPattern: String,
                holdOrientation: String, pitchDeg: Double?, rollDeg: Double?,
                actualSampleRate: Double, ioBufferDuration: Double?, notes: String? = nil) {
        self.config = config
        self.label = label
        self.deviceModel = deviceModel
        self.appVersion = appVersion
        timestampIso = ISO8601DateFormatter().string(from: timestamp)
        self.micSource = micSource
        self.polarPattern = polarPattern
        self.holdOrientation = holdOrientation
        self.pitchDeg = pitchDeg
        self.rollDeg = rollDeg
        temperatureC = config.temperatureC
        self.actualSampleRate = actualSampleRate
        self.ioBufferDuration = ioBufferDuration
        self.notes = notes
    }

    public func encodeJSON() throws -> Data {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }
}
