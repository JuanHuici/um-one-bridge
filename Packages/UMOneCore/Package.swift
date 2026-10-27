// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UMOneCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "UMOneCore", targets: ["UMOneCore"]),
        .executable(name: "umone-diag", targets: ["umone-diag"]),
    ],
    targets: [
        .target(name: "UMOneCore"),
        .executableTarget(name: "umone-diag", dependencies: ["UMOneCore"]),
        .testTarget(name: "UMOneCoreTests", dependencies: ["UMOneCore"]),
    ]
)
