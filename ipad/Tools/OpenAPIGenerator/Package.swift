// swift-tools-version: 6.0
import PackageDescription

// Pins the swift-openapi-generator CLI used by ../regenerate-api-client.sh, kept apart from
// BookOrbitKit so the app never resolves the generator's build-time dependencies.
let package = Package(
    name: "OpenAPIGenerator",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", exact: "1.13.1")
    ]
)
