// swift-tools-version:5.9
import PackageDescription

// Uses the actual production products, including their real native dependencies.
// No copied or substitute App/Processing/Storage/Database module is declared here.
let products: [Target.Dependency] = ["App", "Processing", "Storage", "Shared", "Database"].map {
    .product(name: $0, package: "Retrace")
}
let package = Package(
    name: "RetraceAudioIntegrationValidation",
    platforms: [.macOS(.v13)],
    dependencies: [.package(name: "Retrace", path: "..")],
    targets: [
        .testTarget(name: "AudioPolicyIntegrationTests", dependencies: products,
            path: "App/Tests", sources: ["AudioWriterPolicyTests.swift"]),
        .testTarget(name: "NativeFirstPassIntegrationTests", dependencies: products,
            path: "Processing/Tests", exclude: ["Fixtures"],
            sources: ["NativeFirstPassPersistenceTests.swift"]),
        .testTarget(name: "AACIntegrationTests", dependencies: products,
            path: "Storage/Tests", sources: ["AACContainerCompactorTests.swift"])
    ]
)
