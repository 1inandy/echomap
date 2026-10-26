import Foundation
import Testing
@testable import EchoCore

/// A5: pure logic modules.
@Suite struct HapticMapperTests {
    @Test func bandsByDistance() {
        #expect(DistanceBand.of(0.3) == .urgent)
        #expect(DistanceBand.of(0.5) == .near)
        #expect(DistanceBand.of(1.5) == .mid)
        #expect(DistanceBand.of(2.99) == .far)
        #expect(DistanceBand.of(3.0) == .beyond)
    }

    @Test func firstEstimateSetsBandImmediately() {
        var m = HapticMapper()
        #expect(m.update(1.5) == .mid)
    }

    @Test func movingFartherNeedsMarginAndTwoConfirmations() {
        var m = HapticMapper()
        m.update(0.8)
        #expect(m.update(1.05) == .near) // inside the 0.10 m margin
        #expect(m.update(1.05) == .near)
        #expect(m.update(1.15) == .near) // passed, 1 of 2
        #expect(m.update(1.20) == .mid)  // 2 of 2
    }

    @Test func movingNearerNeedsMarginAndTwoConfirmations() {
        var m = HapticMapper()
        m.update(1.5)
        #expect(m.update(0.95) == .mid)
        #expect(m.update(0.85) == .mid)
        #expect(m.update(0.85) == .near)
    }

    @Test func interruptedConfirmationResets() {
        var m = HapticMapper()
        m.update(1.5)
        #expect(m.update(2.2) == .mid)
        #expect(m.update(1.6) == .mid) // back in band: pending cleared
        #expect(m.update(2.2) == .mid)
        #expect(m.update(2.25) == .far)
    }

    @Test func jumpAcrossSeveralBands() {
        var m = HapticMapper()
        m.update(0.3)
        m.update(2.5)
        #expect(m.update(2.5) == .far)
    }

    @Test func noReadingPatternDiffersFromEveryBand() {
        let nr = HapticPattern.noReading.spec
        for b in DistanceBand.allCases {
            let s = HapticPattern.band(b).spec
            #expect(s != nr)
            #expect(s.taps.count == 1 && nr.taps.count == 2)
        }
        #expect(nr.sharpness < HapticPattern.band(.beyond).spec.sharpness)
        // Closer = faster.
        let periods = DistanceBand.allCases.map { HapticPattern.band($0).spec.period }
        #expect(periods == periods.sorted())
    }

    @Test func neverSilentWhileScanning() {
        var f = ScanFeedback()
        f.start()
        for d in [nil, 1.0, nil, nil, 5.0, 2.5] as [Double?] {
            let o = f.update(d)
            #expect(o.pattern != .stopped)
            #expect(o.pattern.spec.taps.count > 0)
        }
        #expect(f.stop().pattern == .stopped)
    }
}

@Suite struct ScanFeedbackTests {
    @Test func medianOfLastThreeAccepted() {
        var f = ScanFeedback()
        f.start()
        _ = f.update(1.0)
        _ = f.update(1.2)
        let o = f.update(3.0)
        #expect(o.displayDistance == 1.2)
        let o2 = f.update(1.1)
        #expect(o2.displayDistance == 1.2) // median of 1.2, 3.0, 1.1
    }

    @Test func oneSuppressedKeepsReadingTwoSwitchToNoReading() {
        var f = ScanFeedback()
        f.start()
        _ = f.update(1.5)
        let a = f.update(nil)
        #expect(a.displayDistance == 1.5 && a.pattern == .band(.mid) && !a.changed)
        let b = f.update(nil)
        #expect(b.displayDistance == nil && b.pattern == .noReading && b.changed)
        // History was cleared: the next estimate stands alone.
        #expect(f.update(2.5).displayDistance == 2.5)
    }

    @Test func suppressedAtStartIsNoReading() {
        var f = ScanFeedback()
        f.start()
        #expect(f.update(nil).pattern == .noReading)
    }
}

@Suite struct CalibrationTests {
    @Test func offsetOnly() throws {
        let fit = try Calibration.fit(truth: [1, 1, 1], rawRanges: [0.93, 0.95, nil])
        #expect(fit.scale == 1)
        #expect(abs(fit.offset - 0.06) < 1e-12)
        #expect(abs(fit.reliability - 2.0 / 3) < 1e-12)
        #expect(abs(fit.residual - 0.01) < 1e-12)
    }

    @Test func twoPoint() throws {
        let truth = [1.0, 1, 2, 2]
        let raw = truth.map { ($0 - 0.05) / 1.02 }
        let fit = try Calibration.fit(truth: truth, rawRanges: raw)
        #expect(abs(fit.scale - 1.02) < 1e-9 && abs(fit.offset - 0.05) < 1e-9 && fit.residual < 1e-9)
    }

    @Test func noValidBurstsThrows() {
        #expect(throws: EchoError.noValidBursts) { try Calibration.fit(truth: [1], rawRanges: [nil]) }
    }

    @Test func endToEndOnFixture() throws {
        // Calibrate on the 1.00 m scene, then read the 2.00 m scene.
        let cfg = SignalConfig.default
        let tpl = try LeakageTemplate.build(from: Fixtures.f32("open_space.f32"), config: cfg)
        let est = RangeEstimator(config: cfg)
        let r1 = est.processBurst(try Fixtures.f32("scene_01.f32"), template: tpl)
        let fit = try Calibration.fit(truth: [1.0], rawRanges: [r1.rawRange])
        let r2 = est.processBurst(try Fixtures.f32("scene_03.f32"), template: tpl, offset: fit.offset, scale: fit.scale)
        #expect(abs(r2.distance! - 2.0) < 0.01)
    }

    @Test func profileRoundTripsTemplate() throws {
        let tpl = LeakageTemplate.ideal(.default)
        let p = CalibrationProfile(deviceModel: "iPhone15,4", micSource: "bottom", polarPattern: "omni",
                                   sampleRate: 48_000, f0: 18_000, f1: 20_000, offsetM: 0.07, scale: 1,
                                   detectionK: 6, template: tpl, reliability: 1, residualM: 0.01)
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(CalibrationProfile.self, from: data)
        let t2 = try #require(back.template)
        #expect(t2.pre == tpl.pre && t2.count == tpl.count)
        let scale = tpl.re.map(abs).max()!
        #expect(zip(t2.re, tpl.re).map { abs($0 - $1) }.max()! / scale < 1e-6)
        #expect(back.matches(.default) && !back.matches(.audibleDev))
    }
}

@Suite struct ExportTests {
    static func sampleTrials() -> [TrialRecord] {
        let cfg = SignalConfig.default
        let est = RangeEstimator(config: cfg)
        let ideal = LeakageTemplate.ideal(cfg)
        let calibrated = try? LeakageTemplate.build(from: Fixtures.f32("open_space.f32"), config: cfg)
        // Same template each scene was generated with (see lab/make_fixtures.py).
        let templates: [LeakageTemplate?] = [ideal, nil, calibrated]
        var out: [TrialRecord] = []
        for (i, (scene, truth, note)) in [("scene_05", 0.75, "clean, \"ideal\" template"),
                                          ("scene_06", 1.00, "no subtraction"),
                                          ("scene_09", 1.50, "low SNR\nsuppressed")].enumerated() {
            let r = est.processBurst((try? Fixtures.f32("\(scene).f32")) ?? [], template: templates[i])
            out.append(TrialRecord(trialId: "swift-\(i)", sessionId: "fixture",
                                   timestamp: Date(timeIntervalSince1970: 1_790_000_000 + Double(i)),
                                   appVersion: "0.1.0", deviceModel: "macOS-test", mode: .experiment,
                                   config: cfg, result: r, actualDistanceM: truth, environment: "sim",
                                   surfaceMaterial: "drywall", holdOrientation: "A", micSource: "bottom",
                                   polarPattern: "omni", notes: note))
        }
        return out
    }

    @Test func csvHeaderMatchesPlanAndQuotes() {
        let csv = TrialCSV.encode(Self.sampleTrials())
        let header = csv.components(separatedBy: "\r\n")[0]
        #expect(header.split(separator: ",").count == 35)
        #expect(header.hasPrefix("trial_id,session_id,timestamp_iso"))
        #expect(header.hasSuffix("calibration_id,notes"))
        #expect(csv.contains("\"clean, \"\"ideal\"\" template\""))
        #expect(csv.contains("\"low SNR\nsuppressed\""))
    }

    @Test func suppressedTrialHasNoEstimate() {
        let t = Self.sampleTrials()[2]
        #expect(t.suppressed && t.estimatedDistanceM == nil && t.absoluteErrorM == nil)
    }

    /// Writes the fixture that `lab/tests/test_stats_io.py` reads back (CSV round trip).
    @Test func writeCSVFixtureForPython() throws {
        let csv = TrialCSV.encode(Self.sampleTrials())
        try csv.write(to: Fixtures.root.appendingPathComponent("trials_from_swift.csv"),
                      atomically: true, encoding: .utf8)
    }

    /// Writes a Capture Lab style WAV + sidecar that `read_capture` must load.
    @Test func writeWAVFixtureForPython() throws {
        let cfg = SignalConfig.default
        let burst = ChirpGenerator.burst(cfg)
        let wav = WAVEncoder.encode(burst, sampleRate: Int(cfg.fs))
        #expect(wav.count == 44 + burst.count * 4)
        let url = Fixtures.root.appendingPathComponent("capture_from_swift.wav")
        try wav.write(to: url)
        let meta = CaptureMetadata(config: cfg, label: "fixture", deviceModel: "macOS-test",
                                   appVersion: "0.1.0", micSource: "bottom", polarPattern: "omni",
                                   holdOrientation: "A", pitchDeg: 0, rollDeg: 0,
                                   actualSampleRate: 48_000, ioBufferDuration: 0.005)
        try meta.encodeJSON().write(to: url.deletingPathExtension().appendingPathExtension("json"))
    }

    @Test func statsPercentileMatchesNumpy() {
        #expect(Stats.percentile([1, 2, 3, 4], 90) == 3.7)
        #expect(Stats.percentile([5], 90) == 5)
        let s = Stats.summarize(Self.sampleTrials())
        #expect(s.n == 3 && s.accepted == 2)
        #expect(abs(s.coverage - 2.0 / 3) < 1e-12)
    }

    @Test func configJSONRoundTrip() throws {
        var c = SignalConfig.audibleDev
        c.temperatureC = 25
        #expect(try SignalConfig.decode(json: c.encodeJSON()) == c)
        // Older files with missing keys still decode.
        #expect(try SignalConfig.decode(json: Data("{\"f0\": 17000}".utf8)).f0 == 17_000)
    }

    @Test func burstLayout() {
        let cfg = SignalConfig.default
        let b = ChirpGenerator.burst(cfg)
        #expect(b.count == 5 * 4800)
        #expect(b[480..<4800].allSatisfy { $0 == 0 })
        #expect(b[4800..<5280].contains { $0 != 0 })
    }
}
