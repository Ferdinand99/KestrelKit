// swift-tools-version: 6.0
// Swift 6 language mode (strict concurrency) is the default for tools version 6.0.

import PackageDescription

let package = Package(
    name: "KestrelKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v9),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "KestrelKit", targets: ["KestrelKit"]),
    ],
    targets: [
        .target(
            name: "KestrelKit",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "KestrelKitTests",
            dependencies: ["KestrelKit"]
        ),
    ]
)
