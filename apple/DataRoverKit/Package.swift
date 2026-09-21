// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DataRoverKit",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "DataRoverKit", targets: ["DataRoverKit"]),
    ],
    targets: [
        .target(name: "CDataRoverABI"),
        .target(name: "DataRoverKit"),
        .testTarget(name: "DataRoverKitTests", dependencies: ["DataRoverKit"]),
    ]
)
