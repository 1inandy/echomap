import Foundation
@testable import EchoCore

enum Fixtures {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("fixtures")

    static func json(_ name: String) throws -> [String: Any] {
        let d = try Data(contentsOf: root.appendingPathComponent(name))
        return try JSONSerialization.jsonObject(with: d) as! [String: Any]
    }

    static func f32(_ name: String) throws -> [Double] {
        let d = try Data(contentsOf: root.appendingPathComponent(name))
        return d.withUnsafeBytes { raw in
            raw.bindMemory(to: UInt32.self).map { Double(Float(bitPattern: UInt32(littleEndian: $0))) }
        }
    }

    static func config(_ dict: Any) throws -> SignalConfig {
        try SignalConfig.decode(json: JSONSerialization.data(withJSONObject: dict))
    }

    static func template(_ dict: [String: Any]) -> LeakageTemplate {
        let data = dict["data"] as! [Double]
        return LeakageTemplate(re: stride(from: 0, to: data.count, by: 2).map { data[$0] },
                               im: stride(from: 1, to: data.count, by: 2).map { data[$0] },
                               pre: dict["pre"] as! Int)
    }

    static func double(_ v: Any?) -> Double? { v is NSNull ? nil : (v as? NSNumber)?.doubleValue }

    static var sceneCount: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: root.path))?
            .filter { $0.hasPrefix("scene_") && $0.hasSuffix(".json") }.count ?? 0
    }
}
