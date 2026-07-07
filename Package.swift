// swift-tools-version:5.9
import PackageDescription

// Homebrew libpq location (Apple Silicon). Adjust if libpq lives elsewhere.
let libpqInclude = "/opt/homebrew/opt/libpq/include"
let libpqLib = "/opt/homebrew/opt/libpq/lib"

let package = Package(
    name: "Tusk",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Tusk", targets: ["Tusk"]),      // GUI app
        .executable(name: "tuskcli", targets: ["tuskcli"]), // CLI (installed as `tusk`)
    ],
    targets: [
        .systemLibrary(name: "CPostgres", path: "Sources/CPostgres"),

        // Shared core: models + the libpq-backed Database actor. No AppKit/SwiftUI,
        // so the CLI can link it without dragging in the GUI stack.
        .target(
            name: "TuskCore",
            dependencies: ["CPostgres"],
            swiftSettings: [.unsafeFlags(["-I", libpqInclude])],
            linkerSettings: [.unsafeFlags(["-L", libpqLib])]
        ),

        // GUI application.
        .executableTarget(
            name: "Tusk",
            dependencies: ["TuskCore"],
            linkerSettings: [.unsafeFlags(["-L", libpqLib])]
        ),

        // Tiny CLI: `tusk mcp`, `tusk selfcheck`, `tusk doctor`.
        .executableTarget(
            name: "tuskcli",
            dependencies: ["TuskCore"],
            linkerSettings: [.unsafeFlags(["-L", libpqLib])]
        ),
    ]
)
