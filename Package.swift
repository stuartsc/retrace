// swift-tools-version:5.9
import PackageDescription
import Foundation

// MARK: - Whisper.cpp Path Configuration (Bundled)

/// Use bundled whisper.cpp library from Vendors directory
/// This makes the project self-contained - no external dependencies needed for building
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let whisperPath = packageDir + "/Vendors/whisper"
let whisperIncludePath = whisperPath + "/include"
let whisperLibPath = whisperPath + "/lib"

// MARK: - Package Definition

let package = Package(
    name: "Retrace",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "Shared", targets: ["Shared"]),
        .library(name: "Database", targets: ["Database"]),
        .library(name: "Storage", targets: ["Storage"]),
        .library(name: "Capture", targets: ["Capture"]),
        .library(name: "Processing", targets: ["Processing"]),
        .library(name: "Search", targets: ["Search"]),
        .library(name: "Migration", targets: ["Migration"]),
        .library(name: "App", targets: ["App"]),
        .executable(name: "Retrace", targets: ["Retrace"]),
        .executable(name: "TestMostRecentFrame", targets: ["TestMostRecentFrame"]),
        .executable(name: "QueryRewindApps", targets: ["QueryRewindApps"]),
    ],
    dependencies: [
        // NOTE: Dependencies are bundled locally in Vendors/ or will be downloaded at runtime
        // ⚠️ RELEASE 2 ONLY:
        // whisper.cpp - bundled in Vendors/whisper/
        // Models (*.bin, *.gguf) - downloaded at runtime on first launch

        // SQLCipher for reading encrypted Rewind database
        .package(url: "https://github.com/skiptools/swift-sqlcipher.git", from: "1.0.0"),
        // Sparkle for auto-updates
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
        // SwiftyChrono for natural language date parsing (batmac fork with Swift 5.5+ support)
        .package(url: "https://github.com/batmac/SwiftyChrono.git", revision: "e1bf3bde0f09112909157360b6bf39302f10ae5f")
    ],
    targets: [
        // MARK: - Whisper.cpp C library (bundled)
        .systemLibrary(
            name: "CWhisper",
            path: "Vendors/whisper"
        ),

        // MARK: - Shared models and protocols
        .target(
            name: "Shared",
            dependencies: [],
            path: "Shared"
        ),

        // MARK: - Database module
        // NOTE: Uses SQLCipher instead of system SQLite3 because Migration module
        // requires SQLCipher for Rewind database, and we can't mix both in one app.
        // SQLCipher works with unencrypted databases too (just don't set PRAGMA key).
        .target(
            name: "Database",
            dependencies: [
                "Shared",
                .product(name: "SQLCipher", package: "swift-sqlcipher")
            ],
            path: "Database",
            exclude: [
                "Tests",
                "README.md",
                "AGENTS.md",
                "PROGRESS.md"
            ]
        ),
        .testTarget(
            name: "DatabaseTests",
            dependencies: ["Database", "Shared", "Processing", "Storage", "Search"],
            path: "Database/Tests",
            exclude: [
                "_future"  // Release 2+ tests
            ],
            linkerSettings: [
                .unsafeFlags(["-L", whisperLibPath, "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../lib", "-Xlinker", "-rpath", "-Xlinker", whisperLibPath]),
                .linkedLibrary("whisper"),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreML"),
                .linkedFramework("Metal")
            ]
        ),

        // MARK: - Storage module
        .target(
            name: "Storage",
            dependencies: ["Shared"],
            path: "Storage",
            exclude: [
                "Tests",
                "README.md",
                "AGENTS.md",
                "PROGRESS.md"
            ]
        ),
        .testTarget(
            name: "StorageTests",
            dependencies: ["Storage", "Shared"],
            path: "Storage/Tests"
        ),

        // MARK: - Capture module
        .target(
            name: "Capture",
            dependencies: ["Shared"],
            path: "Capture",
            exclude: [
                "Tests",
                "README.md",
                "AGENTS.md",
                "PROGRESS.md"
            ]
        ),
        .testTarget(
            name: "CaptureTests",
            dependencies: ["Capture", "Shared"],
            path: "Capture/Tests"
        ),

        // MARK: - Processing module
        .target(
            name: "Processing",
            dependencies: [
                "Shared",
                "Database",
                "Storage",
                "CWhisper"
            ],
            path: "Processing",
            exclude: [
                "Tests",
                "README.md",
                "AGENTS.md",
                "PROGRESS.md"
            ],
            cSettings: [
                .unsafeFlags(["-I", whisperIncludePath, "-I", whisperIncludePath + "/ggml"])
            ],
            linkerSettings: [
                .unsafeFlags(["-L", whisperLibPath, "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../lib", "-Xlinker", "-rpath", "-Xlinker", whisperLibPath]),
                .linkedLibrary("whisper"),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreML"),
                .linkedFramework("Metal")
            ]
        ),
        .testTarget(
            name: "ProcessingTests",
            dependencies: ["Processing", "Shared", "Database", "Storage"],
            path: "Processing/Tests",
            linkerSettings: [
                .unsafeFlags(["-L", whisperLibPath, "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../lib", "-Xlinker", "-rpath", "-Xlinker", whisperLibPath]),
                .linkedLibrary("whisper"),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreML"),
                .linkedFramework("Metal")
            ]
        ),

        // MARK: - Search module
        .target(
            name: "Search",
            dependencies: [
                "Shared"
            ],
            path: "Search",
            exclude: [
                "Tests",
                "VectorSearchTODO",  // Exclude vector search implementation
                "README.md",
                "AGENTS.md",
                "PROGRESS.md"
            ]
        ),
        .testTarget(
            name: "SearchTests",
            dependencies: ["Search", "Shared", "Database"],
            path: "Search/Tests"
        ),

        // MARK: - Migration module
        .target(
            name: "Migration",
            dependencies: [
                "Shared",
                .product(name: "SQLCipher", package: "swift-sqlcipher")
            ],
            path: "Migration",
            exclude: [
                "README.md",
                "AGENTS.md",
                "PROGRESS.md"
            ]
        ),

        // MARK: - App integration layer
        .target(
            name: "App",
            dependencies: [
                "Shared",
                "Database",
                "Storage",
                "Capture",
                "Processing",
                "Search",
                "Migration",
                .product(name: "SQLCipher", package: "swift-sqlcipher")
            ],
            path: "App",
            exclude: [
                "Tests",
                "README.md"
            ],
            linkerSettings: [
                .unsafeFlags(["-L", whisperLibPath, "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../lib", "-Xlinker", "-rpath", "-Xlinker", whisperLibPath]),
                .linkedLibrary("whisper"),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreML"),
                .linkedFramework("Metal")
            ]
        ),
        .testTarget(
            name: "AppTests",
            dependencies: [
                "App",
                "Shared"
            ],
            path: "App/Tests",
            linkerSettings: [
                .unsafeFlags(["-L", whisperLibPath, "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../lib", "-Xlinker", "-rpath", "-Xlinker", whisperLibPath]),
                .linkedLibrary("whisper"),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreML"),
                .linkedFramework("Metal")
            ]
        ),

        // MARK: - UI module
        .executableTarget(
            name: "Retrace",
            dependencies: [
                "Shared",
                "App",
                "Database",
                "Storage",
                "Capture",
                "Processing",
                "Search",
                "Migration",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "SwiftyChrono", package: "SwiftyChrono")
            ],
            path: "UI",
            exclude: [
                "Tests",
                "README.md",
                "AGENTS.md",
                "Info.plist",
                "Retrace.entitlements"
            ],
            resources: [
                .process("Assets.xcassets")
            ],
            linkerSettings: [
                .unsafeFlags(["-L", whisperLibPath, "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../lib", "-Xlinker", "-rpath", "-Xlinker", whisperLibPath]),
                .linkedLibrary("whisper"),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreML"),
                .linkedFramework("Metal")
            ]
        ),

        // MARK: - Test executable for getMostRecentFrameTimestamp
        .executableTarget(
            name: "TestMostRecentFrame",
            dependencies: [
                "Shared",
                "App"
            ],
            path: "Sources/TestMostRecentFrame"
        ),

        // MARK: - Query Rewind apps utility
        .executableTarget(
            name: "QueryRewindApps",
            dependencies: [
                "Shared",
                .product(name: "SQLCipher", package: "swift-sqlcipher")
            ],
            path: "Sources/QueryRewindApps"
        ),
        .testTarget(
            name: "RetraceTests",
            dependencies: ["Retrace", "Shared", "App"],
            path: "UI/Tests",
            linkerSettings: [
                .unsafeFlags(["-L", whisperLibPath, "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../lib", "-Xlinker", "-rpath", "-Xlinker", whisperLibPath]),
                .linkedLibrary("whisper"),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreML"),
                .linkedFramework("Metal")
            ]
        ),
    ]
)
