// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "EyeballsCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "EyeballsCore", type: .static, targets: ["EyeballsCore"]),
        .library(name: "EyeballsKit", type: .static, targets: ["EyeballsKit"]),
    ],
    targets: [
        .target(name: "EyeballsCore"),
        .target(name: "EyeballsKit"),
        .testTarget(name: "EyeballsCoreTests", dependencies: ["EyeballsCore", "EyeballsKit"]),
    ],
    swiftLanguageModes: [.v6]
)
