// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DataRoverKit",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "DataRoverKit", targets: ["DataRoverKit"]),
        .library(name: "DataRoverShell", targets: ["DataRoverShell"]),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
    ],
    targets: [
        .target(name: "CDataRoverABI"),
        .target(name: "DataRoverKit"),
        // Host web proxy and package downloads. No core dependency, so its
        // tests link without the emulator library.
        .target(name: "DataRoverWeb", dependencies: ["SwiftSoup"]),
        .target(name: "DataRoverShell", dependencies: ["DataRoverKit", "DataRoverWeb", "CDataRoverABI"],
                resources: [.process("Resources")]),
        .testTarget(name: "DataRoverKitTests", dependencies: ["DataRoverKit"]),
        .testTarget(name: "DataRoverWebTests", dependencies: ["DataRoverWeb"]),
    ]
)
