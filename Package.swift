// swift-tools-version:5.9
import PackageDescription

// Homebrew libpq location (Apple Silicon). Adjust if libpq lives elsewhere.
let libpqInclude = "/opt/homebrew/opt/libpq/include"
let libpqLib = "/opt/homebrew/opt/libpq/lib"

let package = Package(
    name: "Tusk",
    platforms: [.macOS(.v13)],
    targets: [
        .systemLibrary(name: "CPostgres", path: "Sources/CPostgres"),
        .executableTarget(
            name: "Tusk",
            dependencies: ["CPostgres"],
            swiftSettings: [
                .unsafeFlags(["-I", libpqInclude])
            ],
            linkerSettings: [
                .unsafeFlags(["-L", libpqLib])
            ]
        ),
    ]
)
