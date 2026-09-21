// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DataRoverKit",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "DataRoverKit", targets: ["DataRoverKit"]),
        .library(name: "DataRoverShell", targets: ["DataRoverShell"]),
    ],
    targets: [
        .target(name: "CDataRoverABI"),
        .target(name: "DataRoverKit"),
        .target(name: "DataRoverShell", dependencies: ["DataRoverKit", "CDataRoverABI"],
                resources: [.process("Resources")]),
        .testTarget(name: "DataRoverKitTests", dependencies: ["DataRoverKit"]),
    ]
)
