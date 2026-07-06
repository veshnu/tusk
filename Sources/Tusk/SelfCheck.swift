import Foundation

/// Headless verification of the real libpq code path (connect / test / snapshot /
/// columns) against a live Postgres. Triggered with `Tusk --selfcheck`.
/// Reads standard PG* env vars; falls back to the local docker defaults.
enum SelfCheck {
    private static func env(_ key: String, _ fallback: String) -> String {
        let v = ProcessInfo.processInfo.environment[key]
        return (v?.isEmpty == false) ? v! : fallback
    }

    static func run() -> Never {
        let cfg = Connection(
            name: "selfcheck",
            host: env("PGHOST", "localhost"),
            port: env("PGPORT", "5432"),
            database: env("PGDATABASE", "app_dev"),
            user: env("PGUSER", "postgres"),
            sslMode: env("PGSSLMODE", "prefer"),
            savePassword: false,
            env: "local",
            password: env("PGPASSWORD", "hunter2")
        )
        let db = Database()
        let sem = DispatchSemaphore(value: 0)
        Task {
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
                let cols = try await db.columns(database: cfg.database, schema: "public", table: "orders")
                print("COLUMNS public.orders:")
                for c in cols {
                    let flags = [c.isPK ? "PK" : nil, c.isFK ? "FK" : nil, c.notNull ? "NOT NULL" : nil]
                        .compactMap { $0 }.joined(separator: " ")
                    print("  \(c.name): \(c.type) \(flags)")
                }
                print("SELFCHECK_OK")
            } catch {
                print("SELFCHECK_FAIL: \(error.localizedDescription)")
            }
            sem.signal()
        }
        sem.wait()
        exit(0)
    }
}
