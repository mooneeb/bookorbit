// swift-tools-version: 6.2
import PackageDescription

// One target per feature, so tickets that run in parallel touch disjoint folders. Features depend
// on BookOrbitFeatureKit for the app shell's extension point, never on each other's internals.
// Lists keep one entry per line so parallel additions merge cleanly.
let package = Package(
    name: "BookOrbitKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macCatalyst(.v26), .macOS(.v26)],
    products: [
        .library(name: "BookOrbitFeatures", targets: ["BookOrbitFeatures"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.12.2"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.3.1"),
    ],
    targets: [
        .target(
            name: "BookOrbitFeatures",
            dependencies: [
                "BookOrbitAPI",
                "BookOrbitCore",
                "BookOrbitAuth",
                "BookOrbitFeatureKit",
                "BookOrbitLibrary",
                "BookOrbitPDFReader",
                "BookOrbitEPUBReader",
                "BookOrbitComicsReader",
                "BookOrbitInk",
                "BookOrbitSync",
                "BookOrbitMyLibrary",
                "BookOrbitListening",
                "BookOrbitSettings",
                "BookOrbitAdmin",
            ]
        ),
        .target(
            name: "BookOrbitAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ]
        ),
        .target(name: "BookOrbitCore"),
        .target(
            name: "BookOrbitAuth",
            dependencies: [
                "BookOrbitAPI",
                "BookOrbitCore",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            ]
        ),
        .target(name: "BookOrbitFeatureKit", dependencies: ["BookOrbitAPI", "BookOrbitAuth"]),
        .target(name: "BookOrbitLibrary", dependencies: ["BookOrbitAPI", "BookOrbitAuth", "BookOrbitFeatureKit"]),
        .target(name: "BookOrbitPDFReader", dependencies: ["BookOrbitFeatureKit", "BookOrbitInk", "BookOrbitSync"]),
        .target(
            name: "BookOrbitEPUBReader",
            dependencies: ["BookOrbitFeatureKit", "BookOrbitSync"],
            resources: [.copy("Resources")]
        ),
        .target(name: "BookOrbitComicsReader", dependencies: ["BookOrbitFeatureKit", "BookOrbitInk", "BookOrbitSync"]),
        .target(name: "BookOrbitInk", dependencies: ["BookOrbitAPI", "BookOrbitAuth"]),
        .target(name: "BookOrbitSync", dependencies: ["BookOrbitAPI", "BookOrbitAuth"]),
        .target(name: "BookOrbitMyLibrary", dependencies: ["BookOrbitFeatureKit"]),
        .target(name: "BookOrbitListening", dependencies: ["BookOrbitFeatureKit"]),
        .target(name: "BookOrbitSettings", dependencies: ["BookOrbitFeatureKit"]),
        .target(name: "BookOrbitAdmin", dependencies: ["BookOrbitFeatureKit"]),
        .target(name: "BookOrbitTestSupport", dependencies: ["BookOrbitAuth"], path: "Tests/BookOrbitTestSupport"),
        .testTarget(name: "BookOrbitCoreTests", dependencies: ["BookOrbitCore"]),
        .testTarget(name: "BookOrbitAuthTests", dependencies: ["BookOrbitAuth", "BookOrbitTestSupport"]),
        .testTarget(name: "BookOrbitFeatureKitTests", dependencies: ["BookOrbitFeatureKit", "BookOrbitTestSupport"]),
        .testTarget(name: "BookOrbitLibraryTests", dependencies: ["BookOrbitLibrary", "BookOrbitTestSupport"]),
    ]
)
