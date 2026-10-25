// swift-tools-version: 6.0
//
// RemoteCodeKit — shared code for the Remote Code Mac and iOS apps.
//
// * `RemoteCodeKit`  — wire protocol, models, crypto, transports, client and
//                      server connection logic, demo server. Used by both apps.
// * `RemoteCodeHost` — Mac-side core: Claude CLI supervision, stream-json
//                      normaliser, event log, file browser, permission broker.
//
// Both targets are platform-neutral so the core is testable with `swift test`
// on macOS and Linux. On Apple platforms the package has no dependencies;
// on Linux Apple's swift-crypto stands in for CryptoKit (docs/DECISIONS.md D-013).

import PackageDescription

var packageDependencies: [Package.Dependency] = []
var kitDependencies: [Target.Dependency] = []

#if os(Linux)
packageDependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"))
kitDependencies.append(.product(name: "Crypto", package: "swift-crypto"))
#endif

let package = Package(
    name: "RemoteCodeKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "RemoteCodeKit", targets: ["RemoteCodeKit"]),
        .library(name: "RemoteCodeHost", targets: ["RemoteCodeHost"]),
    ],
    dependencies: packageDependencies,
    targets: [
        .target(
            name: "RemoteCodeKit",
            dependencies: kitDependencies
        ),
        .target(
            name: "RemoteCodeHost",
            dependencies: ["RemoteCodeKit"]
        ),
        .testTarget(
            name: "RemoteCodeKitTests",
            dependencies: ["RemoteCodeKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "RemoteCodeHostTests",
            dependencies: ["RemoteCodeHost"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
