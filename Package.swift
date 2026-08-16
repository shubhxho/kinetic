// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kinetic",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Kinetic", targets: ["Kinetic"]),
        .library(name: "KineticML", targets: ["KineticML"]),
        .library(name: "KineticRender", targets: ["KineticRender"]),
        .library(name: "KineticBridge", targets: ["KineticBridge"]),
        .executable(name: "kinetic", targets: ["KineticCLI"]),
        .executable(name: "KineticStudio", targets: ["KineticStudio"]),
    ],
    dependencies: [
        // MLX gives Kinetic on-device training and inference on the same GPU the
        // viewport is already using, with no Python runtime in the loop.
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.31.0"),
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

        // ── On-device machine learning ────────────────────────────────────
        .target(
            name: "KineticML",
            dependencies: [
                "Kinetic",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXOptimizers", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
            ],
            path: "Sources/KineticML"
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
            dependencies: ["Kinetic", "KineticRender", "KineticBridge", "KineticML"],
            path: "Sources/KineticCLI"
        ),
        .executableTarget(
            name: "KineticStudio",
            dependencies: ["Kinetic", "KineticRender", "KineticBridge", "KineticML"],
            path: "Sources/KineticStudio",
            resources: [.copy("Resources")]
        ),

        // ── Tests ─────────────────────────────────────────────────────────
        .testTarget(
            name: "KineticTests",
            dependencies: ["Kinetic", "KineticBridge", "KineticML"],
            path: "Tests/KineticTests",
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx20
)
