import Foundation
import TuskCore

// Tiny companion CLI for the Tusk app. This binary is installed on PATH as `tusk`
// (the build product is named `tuskcli` only to avoid a case-insensitive clash
// with the `Tusk` app binary). Claude Code and other MCP clients spawn `tusk mcp`.

let toolVersion = "0.1.0"

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first

func env(_ key: String, _ fallback: String) -> String {
    let v = ProcessInfo.processInfo.environment[key]
    return (v?.isEmpty == false) ? v! : fallback
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func printUsage() {
    print("""
    tusk — companion CLI for the Tusk database app

    USAGE:
      tusk <command> [options]

    COMMANDS:
      mcp         Start the MCP server over stdio (for Claude Code & other MCP clients)
      selfcheck   Verify the libpq path against a live Postgres (reads PG* env vars)
      doctor      Check the local environment (libpq, app install)
      version     Print the version
      help        Show this help
    """)
}

func runDoctor() {
    print("tusk doctor")
    let libpqCandidates = [
        "/opt/homebrew/opt/libpq/lib/libpq.5.dylib",
        "/usr/local/opt/libpq/lib/libpq.5.dylib",
        "/usr/lib/libpq.5.dylib",
    ]
    let libpq = libpqCandidates.first { FileManager.default.fileExists(atPath: $0) }
    print("  libpq:    \(libpq ?? "NOT FOUND — run `brew install libpq`")")

    let app = "/Applications/Tusk.app"
    let appInstalled = FileManager.default.fileExists(atPath: app)
    print("  Tusk.app: \(appInstalled ? app : "not installed in /Applications")")
    print("  version:  \(toolVersion)")
}

/// Headless verification of the real libpq code path against a live Postgres.
/// Reads standard PG* env vars; falls back to local defaults.
func runSelfCheck() async {
    let cfg = Connection(
        name: "selfcheck",
        host: env("PGHOST", "localhost"),
        port: env("PGPORT", "5432"),
        database: env("PGDATABASE", "postgres"),
        user: env("PGUSER", "postgres"),
        sslMode: env("PGSSLMODE", "prefer"),
        savePassword: false,
        env: "local",
        password: env("PGPASSWORD", "")
    )
    let db = Database()
    do {
        let t = try await db.test(cfg)
        print(String(format: "TEST ok: %.1f ms · %@", t.latencyMs, t.serverVersion))

        try await db.open(cfg)
        let dbs = try await db.databases()
        print("DATABASES: \(dbs.joined(separator: ", "))")

        let snap = try await db.snapshot(database: cfg.database)
        print("DATABASE: \(snap.database)  (\(snap.relations.count) relations)")
        for r in snap.relations {
            print("  [\(r.kind.rawValue)] \(r.schema).\(r.name)  ~\(Fmt.rows(r.estRows))")
        }
        print("SELFCHECK_OK")
    } catch {
        print("SELFCHECK_FAIL: \(error.localizedDescription)")
        exit(1)
    }
}

switch command {
case "version", "--version", "-v":
    print("tusk \(toolVersion)")
case "help", "--help", "-h", nil:
    printUsage()
case "doctor":
    runDoctor()
case "selfcheck":
    await runSelfCheck()
case "mcp":
    warn("tusk mcp: the MCP server is not implemented yet.")
    exit(1)
default:
    warn("Unknown command: \(command ?? "")\n")
    printUsage()
    exit(64)
}
