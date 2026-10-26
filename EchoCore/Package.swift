// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EchoCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "EchoCore", targets: ["EchoCore"]),
    ],
    targets: [
        .target(name: "EchoCore"),
        .testTarget(name: "EchoCoreTests", dependencies: ["EchoCore"]),
    ]
)
