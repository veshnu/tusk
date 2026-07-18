import Foundation
import MachO
import TuskCore

// Tiny companion CLI for the Tusk app. This binary is installed on PATH as `tusk`
// (the build product is named `tuskcli` only to avoid a case-insensitive clash
// with the `Tusk` app binary). Claude Code and other MCP clients spawn `tusk mcp`.

let toolVersion = TuskVersion.current

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first

func env(_ key: String, _ fallback: String) -> String {
    let v = ProcessInfo.processInfo.environment[key]
    return (v?.isEmpty == false) ? v! : fallback
}

/// A connection assembled from standard PG* environment variables.
func connectionFromEnv() -> Connection {
    Connection(
        name: "cli",
        host: env("PGHOST", "localhost"),
        port: env("PGPORT", "5432"),
        database: env("PGDATABASE", "postgres"),
        user: env("PGUSER", "postgres"),
        sslMode: env("PGSSLMODE", "prefer"),
        savePassword: false,
        env: "local",
        password: env("PGPASSWORD", "")
    )
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
      mcp           Bridge Claude Code's stdio to the running app's MCP socket
                    (falls back to serving over stdio from PG* env if the app isn't running)
      mcp --serve   Run the MCP server headlessly on the unix socket (PG* env connection)
      selfcheck     Verify the libpq path against a live Postgres (reads PG* env vars)
      doctor        Check the local environment (libpq, app install)
      version       Print the version
      help          Show this help
    """)
}

/// The libpq this process actually loaded, straight from dyld.
///
/// Probing well-known paths on disk would be a lie: releases vendor libpq into
/// Tusk.app/Contents/Frameworks and load it via @rpath, so a Homebrew libpq may
/// exist on the machine without being the one in use — or, on a user's Mac, not
/// exist at all while Tusk works fine.
func loadedLibpqPath() -> String? {
    (0..<_dyld_image_count()).lazy
        .compactMap { _dyld_get_image_name($0) }
        .map { String(cString: $0) }
        .first { $0.contains("libpq") }
}

func runDoctor() {
    print("tusk doctor")
    print("  libpq:    \(loadedLibpqPath() ?? "NOT LOADED — this build is broken")")

    let app = "/Applications/Tusk.app"
    let appInstalled = FileManager.default.fileExists(atPath: app)
    print("  Tusk.app: \(appInstalled ? app : "not installed in /Applications")")
    print("  version:  \(toolVersion)")
}

/// Headless verification of the real libpq code path against a live Postgres.
/// Reads standard PG* env vars; falls back to local defaults.
func runSelfCheck() async {
    let cfg = connectionFromEnv()
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

/// `tusk mcp --serve`: run the socket server headlessly (connection from PG* env).
/// This is what a standalone/daemon deployment uses; the GUI hosts the same server
/// in-process when it's running.
func runMCPServe() async {
    let cfg = connectionFromEnv()
    let db = Database()
    do {
        try await db.open(cfg)
    } catch {
        warn("tusk mcp --serve: could not connect using PG* env vars: \(error.localizedDescription)")
        exit(1)
    }
    let server = MCPSocketServer(provider: EnvTuskProvider(db: db, connection: cfg))
    do {
        try server.start()
    } catch {
        warn("tusk mcp --serve: \(error.localizedDescription)")
        exit(1)
    }
    warn("tusk mcp: serving on \(server.socketPath) (db: \(cfg.database))")
    while true { try? await Task.sleep(nanoseconds: 3_600_000_000_000) } // run until killed
}

/// `tusk mcp`: what Claude Code spawns. Bridge stdio to the running app's socket;
/// if the app isn't hosting one, fall back to serving MCP directly over stdio
/// using a PG* env connection.
func runMCP() async {
    let path = TuskPaths.mcpSocketPath
    if FileManager.default.fileExists(atPath: path) {
        if runMCPSocketBridge(socketPath: path) { exit(0) }
        warn("tusk mcp: found a socket at \(path) but couldn't connect; falling back to stdio.")
    }
    let cfg = connectionFromEnv()
    let db = Database()
    do {
        try await db.open(cfg)
    } catch {
        warn("""
        tusk mcp: no running Tusk MCP socket, and could not open a Postgres connection \
        from PG* env vars: \(error.localizedDescription)
        Open Tusk and connect to a database, or set PGHOST/PGPORT/PGDATABASE/PGUSER/PGPASSWORD.
        """)
        exit(1)
    }
    await runStdioMCPSession(provider: EnvTuskProvider(db: db, connection: cfg))
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
    if arguments.dropFirst().contains("--serve") {
        await runMCPServe()
    } else {
        await runMCP()
    }
default:
    warn("Unknown command: \(command ?? "")\n")
    printUsage()
    exit(64)
}
