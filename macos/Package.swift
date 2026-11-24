// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LightRig",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LightRig", targets: ["CanonRig"]),
        .library(name: "CanonRigCore", targets: ["CanonRigCore"]),
    ],
    targets: [
        .target(name: "CanonRigCore"),
        .executableTarget(name: "CanonRig", dependencies: ["CanonRigCore"]),
        .testTarget(name: "AppUpdateTests", dependencies: ["CanonRig"]),
        .testTarget(name: "CanonRigCoreTests", dependencies: ["CanonRigCore"]),
    ]
)
