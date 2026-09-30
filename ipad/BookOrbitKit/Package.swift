// swift-tools-version: 6.2
import PackageDescription

// One target per feature so tickets that run in parallel touch disjoint folders. Features depend
// on BookOrbitFeatureKit for the app shell's extension point, never on each other's internals.
let package = Package(
    name: "BookOrbitKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macCatalyst(.v26), .macOS(.v26)],
    products: [
        .library(name: "BookOrbitFeatures", targets: ["BookOrbitFeatures"]),
        .library(name: "BookOrbitAPI", targets: ["BookOrbitAPI"]),
        .library(name: "BookOrbitAuth", targets: ["BookOrbitAuth"]),
        .library(name: "BookOrbitFeatureKit", targets: ["BookOrbitFeatureKit"]),
        .library(name: "BookOrbitLibrary", targets: ["BookOrbitLibrary"]),
        .library(name: "BookOrbitPDFReader", targets: ["BookOrbitPDFReader"]),
        .library(name: "BookOrbitEPUBReader", targets: ["BookOrbitEPUBReader"]),
        .library(name: "BookOrbitComicsReader", targets: ["BookOrbitComicsReader"]),
        .library(name: "BookOrbitInk", targets: ["BookOrbitInk"]),
        .library(name: "BookOrbitSync", targets: ["BookOrbitSync"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.12.2"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.3.1"),
    ],
    targets: [
        .target(
            name: "BookOrbitAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ]
        ),
        .target(
            name: "BookOrbitAuth",
            dependencies: ["BookOrbitAPI", .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime")]
        ),
        .target(name: "BookOrbitFeatureKit", dependencies: ["BookOrbitAPI", "BookOrbitAuth"]),
        .target(name: "BookOrbitLibrary", dependencies: ["BookOrbitAPI", "BookOrbitAuth", "BookOrbitFeatureKit"]),
        .target(name: "BookOrbitPDFReader", dependencies: ["BookOrbitFeatureKit", "BookOrbitInk", "BookOrbitSync"]),
        .target(name: "BookOrbitEPUBReader", dependencies: ["BookOrbitFeatureKit", "BookOrbitSync"]),
        .target(name: "BookOrbitComicsReader", dependencies: ["BookOrbitFeatureKit", "BookOrbitInk", "BookOrbitSync"]),
        .target(name: "BookOrbitInk", dependencies: ["BookOrbitAPI", "BookOrbitAuth"]),
        .target(name: "BookOrbitSync", dependencies: ["BookOrbitAPI", "BookOrbitAuth"]),
        .target(
            name: "BookOrbitFeatures",
            dependencies: [
                "BookOrbitAPI", "BookOrbitAuth", "BookOrbitFeatureKit", "BookOrbitLibrary", "BookOrbitPDFReader",
                "BookOrbitEPUBReader", "BookOrbitComicsReader", "BookOrbitInk", "BookOrbitSync",
            ]
        ),
        .target(name: "BookOrbitTestSupport", dependencies: ["BookOrbitAuth"], path: "Tests/BookOrbitTestSupport"),
        .testTarget(name: "BookOrbitAuthTests", dependencies: ["BookOrbitAuth", "BookOrbitTestSupport"]),
        .testTarget(name: "BookOrbitFeatureKitTests", dependencies: ["BookOrbitFeatureKit", "BookOrbitTestSupport"]),
        .testTarget(name: "BookOrbitLibraryTests", dependencies: ["BookOrbitLibrary", "BookOrbitTestSupport"]),
    ]
)
