import Foundation
import Testing
@testable import EchoCore

/// A4: Swift matches the Python reference on the golden fixtures within 1 sample on lags,
/// 5 mm on distance and 0.02 on confidence components.
@Suite struct ParityTests {
    static func maxAbsDiff(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).map { abs($0 - $1) }.max() ?? 0
    }

    @Test func configDecodesToDefault() throws {
        let cfg = try Fixtures.config(Fixtures.json("config.json")["config"]!)
        #expect(cfg == SignalConfig.default)
        #expect(try Fixtures.json("config.json")["algo_version"] as? String == SignalConfig.algoVersion)
    }

    @Test func bandPassTapsMatch() throws {
        let py = try Fixtures.json("config.json")["bandpass_taps"] as! [Double]
        let sw = BandPassFilter.taps(.default)
        #expect(sw.count == py.count)
        #expect(Self.maxAbsDiff(sw, py) < 1e-12)
    }

    @Test func filteredReferenceMatches() throws {
        let py = try Fixtures.json("config.json")["filtered_reference"] as! [Double]
        let sw = MatchedFilter.filteredReference(.default)
        #expect(sw.count == py.count)
        #expect(Self.maxAbsDiff(sw, py) < 1e-9)
    }

    @Test func idealTemplateMatches() throws {
        let py = Fixtures.template(try Fixtures.json("config.json")["ideal_template"] as! [String: Any])
        let sw = LeakageTemplate.ideal(.default)
        #expect(sw.pre == py.pre && sw.count == py.count)
        let scale = py.re.map(abs).max()!
        #expect(Self.maxAbsDiff(sw.re, py.re) / scale < 1e-6)
        #expect(Self.maxAbsDiff(sw.im, py.im) / scale < 1e-6)
    }

    @Test func calibratedTemplateMatches() throws {
        let py = Fixtures.template(try Fixtures.json("template.json"))
        let sw = try LeakageTemplate.build(from: Fixtures.f32("open_space.f32"), config: .default)
        #expect(sw.pre == py.pre && sw.count == py.count)
        let scale = py.re.map(abs).max()!
        #expect(Self.maxAbsDiff(sw.re, py.re) / scale < 1e-6)
        #expect(Self.maxAbsDiff(sw.im, py.im) / scale < 1e-6)
    }

    @Test func autocorrelationPeaksAtLagZero() {
        let ref = MatchedFilter.filteredReference(.default)
        var x = [Double](repeating: 0, count: SignalConfig.default.periodLength)
        for i in 0..<ref.count { x[i] = ref[i] }
        let env = MatchedFilter.analyticXcorr(x, ref).magnitude()
        #expect(env.firstIndex(of: env.max()!) == 0)
    }

    @Test(arguments: 0..<12)
    func scene(_ i: Int) throws {
        let name = String(format: "scene_%02d", i)
        let fx = try Fixtures.json("\(name).json")
        let cfg = try Fixtures.config(fx["config"]!)
        let exp = fx["expected"] as! [String: Any]
        let template: LeakageTemplate? = switch fx["template"] as! String {
        case "calibrated": try LeakageTemplate.build(from: Fixtures.f32("open_space.f32"), config: cfg)
        case "ideal": LeakageTemplate.ideal(cfg)
        default: nil
        }
        let x = try Fixtures.f32("\(name).f32")
        let r = RangeEstimator(config: cfg).processBurst(x, template: template)
        let label = "\(name) \(fx["name"]!)"

        let chirps = exp["chirps"] as! [[String: Any]]
        #expect(r.chirps.count == chirps.count, "\(label)")
        for (c, e) in zip(r.chirps, chirps) {
            #expect(abs(c.tauDirect - Fixtures.double(e["tau_direct"])!) < 1, "\(label) tau_direct")
            let te = Fixtures.double(e["tau_echo"])
            #expect((c.tauEcho == nil) == (te == nil), "\(label) echo presence")
            if let a = c.tauEcho, let b = te { #expect(abs(a - b) < 1, "\(label) tau_echo") }
            if let a = c.distance, let b = Fixtures.double(e["distance"]) {
                #expect(abs(a - b) < 0.005, "\(label) chirp distance")
            }
        }
        #expect(r.valid == exp["valid"] as! Int, "\(label) valid")
        #expect(r.category.rawValue == exp["category"] as! String, "\(label) category")
        if let a = r.distance, let b = Fixtures.double(exp["distance"]) {
            #expect(abs(a - b) < 0.005, "\(label) burst distance")
        } else {
            #expect(r.distance == nil && Fixtures.double(exp["distance"]) == nil, "\(label) suppression")
        }
        if let c = r.confidence, let e = exp["confidence"] as? [String: Any] {
            #expect(abs(c.snr - Fixtures.double(e["snr"])!) < 0.02, "\(label) snr")
            #expect(abs(c.consistency - Fixtures.double(e["consistency"])!) < 0.02, "\(label) consistency")
            #expect(abs(c.detection - Fixtures.double(e["detection"])!) < 0.02, "\(label) detection")
            #expect(abs(c.prominence - Fixtures.double(e["prominence"])!) < 0.02, "\(label) prominence")
        } else {
            #expect(r.confidence == nil && exp["confidence"] is NSNull, "\(label) confidence presence")
        }
    }

    @Test func allScenesCovered() {
        #expect(Fixtures.sceneCount == 12)
    }
}
