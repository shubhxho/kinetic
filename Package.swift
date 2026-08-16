// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kinetic",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Kinetic", targets: ["Kinetic"]),
        .library(name: "KineticRender", targets: ["KineticRender"]),
        .library(name: "KineticBridge", targets: ["KineticBridge"]),
        .executable(name: "kinetic", targets: ["KineticCLI"]),
        .executable(name: "KineticStudio", targets: ["KineticStudio"]),
    ],
    targets: [
        // ── C++20 physics core ────────────────────────────────────────────
        .target(
            name: "KineticCore",
            path: "Sources/KineticCore",
            sources: ["src"],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("src"),
                .define("KN_ENABLE_SIMD", to: "1"),
            ]
        ),

        // ── Swift API surface ─────────────────────────────────────────────
        .target(
            name: "Kinetic",
            dependencies: ["KineticCore"],
            path: "Sources/Kinetic"
        ),

        // ── Metal renderer ────────────────────────────────────────────────
        .target(
            name: "KineticRender",
            dependencies: ["Kinetic"],
            path: "Sources/KineticRender",
            resources: [.copy("Resources/Shaders")]
        ),

        // ── Telemetry / Foxglove-compatible bridge ────────────────────────
        .target(
            name: "KineticBridge",
            dependencies: ["Kinetic"],
            path: "Sources/KineticBridge"
        ),

        // ── Apps ──────────────────────────────────────────────────────────
        .executableTarget(
            name: "KineticCLI",
            dependencies: ["Kinetic", "KineticRender", "KineticBridge"],
            path: "Sources/KineticCLI"
        ),
        .executableTarget(
            name: "KineticStudio",
            dependencies: ["Kinetic", "KineticRender", "KineticBridge"],
            path: "Sources/KineticStudio",
            resources: [.copy("Resources")]
        ),

        // ── Tests ─────────────────────────────────────────────────────────
        .testTarget(
            name: "KineticTests",
            dependencies: ["Kinetic", "KineticBridge"],
            path: "Tests/KineticTests",
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx20
)
