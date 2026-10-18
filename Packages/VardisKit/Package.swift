// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VardisKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VardisCore", targets: ["VardisCore"]),
        .library(name: "VardisSampling", targets: ["VardisSampling"]),
        .library(name: "VardisStore", targets: ["VardisStore"]),
        .library(name: "VardisClaude", targets: ["VardisClaude"]),
        .library(name: "VardisCleanup", targets: ["VardisCleanup"]),
    ],
    targets: [
        .target(name: "VardisCore"),
        .target(name: "VardisSampling", dependencies: ["VardisCore"]),
        .target(name: "VardisStore", dependencies: ["VardisCore"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "VardisClaude", dependencies: ["VardisCore", "VardisStore"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "VardisCleanup", dependencies: ["VardisCore"]),
        .testTarget(name: "VardisCoreTests", dependencies: ["VardisCore"]),
        .testTarget(name: "VardisSamplingTests", dependencies: ["VardisSampling"]),
        .testTarget(name: "VardisStoreTests", dependencies: ["VardisStore"]),
        .testTarget(name: "VardisClaudeTests", dependencies: ["VardisClaude"], resources: [.copy("Fixtures")]),
        .testTarget(name: "VardisCleanupTests", dependencies: ["VardisCleanup"]),
    ]
)
