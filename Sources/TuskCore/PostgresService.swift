import Foundation
import CPostgres

// MARK: - Errors & results

public enum PGError: LocalizedError {
    case message(String)
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .message(let m): return m
        case .notConnected: return "Not connected"
        }
    }
}

public struct TestResult: Sendable {
    public let latencyMs: Double
    public let serverVersion: String
}

public struct DBSnapshot: Sendable {
    public let database: String
    public let relations: [Relation]
}

/// A page of rows read from a relation (column names + string-encoded cells; NULL is nil).
public struct RowSet: Sendable {
    public let columns: [String]
    public let rows: [[String?]]
    public init(columns: [String], rows: [[String?]]) {
        self.columns = columns
        self.rows = rows
    }
}

private struct RawResult {
    let columns: [String]
    let rows: [[String?]]
}

// MARK: - libpq helpers

private func withCStringArray<R>(_ strings: [String?], _ body: (UnsafePointer<UnsafePointer<CChar>?>?) -> R) -> R {
    var cStrings: [UnsafePointer<CChar>?] = strings.map { s in
        guard let s else { return nil }
        return UnsafePointer(strdup(s))
    }
    cStrings.append(nil) // null-terminate the keyword/value list
    defer {
        for p in cStrings where p != nil { free(UnsafeMutablePointer(mutating: p)) }
    }
    return cStrings.withUnsafeBufferPointer { buf in body(buf.baseAddress) }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Database actor (one persistent libpq connection per database)

public actor Database {
    /// The config the workspace was opened with. New per-database connections are
    /// cloned from this (same host/port/user/password), overriding only `dbname`.
    private var baseConfig: Connection?
    /// One persistent libpq connection per database name — libpq binds a connection
    /// to a single database, so browsing another DB on the same server needs its own.
    private var conns: [String: OpaquePointer] = [:]

    public init() {}

    // MARK: Connection lifecycle

    /// Open the persistent workspace connection. Throws with the server's message on failure.
    public func open(_ cfg: Connection) throws {
        close()
        baseConfig = cfg
        conns[cfg.database] = try Database.rawConnect(cfg)
    }

    public func close() {
        for (_, c) in conns { PQfinish(c) }
        conns.removeAll()
        baseConfig = nil
    }

    /// An open connection bound to `database`, opening (and caching) one on demand.
    private func connection(for database: String) throws -> OpaquePointer {
        if let c = conns[database] { return c }
        guard var cfg = baseConfig else { throw PGError.notConnected }
        cfg.database = database
        let c = try Database.rawConnect(cfg)
        conns[database] = c
        return c
    }

    /// Test a config with an ephemeral connection; returns latency + server version.
    public func test(_ cfg: Connection) throws -> TestResult {
        let start = DispatchTime.now()
        let c = try Database.rawConnect(cfg)
        defer { PQfinish(c) }
        let res = try Database.exec(c, "SELECT version()")
        let elapsedNs = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        let ms = Double(elapsedNs) / 1_000_000
        let full = res.rows.first?.first.flatMap { $0 } ?? "PostgreSQL"
        // "PostgreSQL 16.2 on aarch64-apple-darwin..." -> "PostgreSQL 16.2"
        let short = full.split(separator: " ").prefix(2).joined(separator: " ")
        return TestResult(latencyMs: ms, serverVersion: short)
    }

    // MARK: Introspection

    /// All databases on the server the user is allowed to connect to (templates excluded).
    public func databases() throws -> [String] {
        guard let cfg = baseConfig else { throw PGError.notConnected }
        let conn = try connection(for: cfg.database)
        let sql = """
        SELECT datname FROM pg_database
        WHERE datallowconn AND NOT datistemplate
        ORDER BY datname
        """
        let res = try Database.exec(conn, sql)
        return res.rows.compactMap { $0.first.flatMap { $0 } }
    }

    /// A snapshot of one database + all its user relations (tables/views/matviews/partitioned).
    public func snapshot(database: String) throws -> DBSnapshot {
        let conn = try connection(for: database)
        let sql = """
        SELECT n.nspname AS schema,
               c.relname AS name,
               c.relkind AS kind,
               COALESCE(c.reltuples, 0)::bigint AS est_rows
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind IN ('r','v','m','p')
          AND n.nspname NOT IN ('pg_catalog','information_schema')
          AND n.nspname NOT LIKE 'pg_temp%%'
          AND n.nspname NOT LIKE 'pg_toast%%'
        ORDER BY n.nspname, c.relname
        """
        let res = try Database.exec(conn, sql)
        let relations: [Relation] = res.rows.compactMap { row in
            guard row.count >= 4,
                  let schema = row[0], let name = row[1], let kind = row[2] else { return nil }
            let est = Int64(row[3] ?? "0") ?? 0
            return Relation(schema: schema, name: name, kind: DBObjectKind.fromRelkind(kind), estRows: est)
        }
        return DBSnapshot(database: database, relations: relations)
    }

    /// Columns for a specific relation, with primary/foreign key flags.
    public func columns(database: String, schema: String, table: String) throws -> [ColumnInfo] {
        let conn = try connection(for: database)
        let sql = """
        SELECT a.attname AS name,
               format_type(a.atttypid, a.atttypmod) AS type,
               a.attnotnull AS notnull,
               COALESCE(bool_or(ct.contype = 'p'), false) AS is_pk,
               COALESCE(bool_or(ct.contype = 'f'), false) AS is_fk
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN pg_constraint ct
               ON ct.conrelid = a.attrelid AND a.attnum = ANY(ct.conkey)
        WHERE n.nspname = $1 AND c.relname = $2
          AND a.attnum > 0 AND NOT a.attisdropped
        GROUP BY a.attname, a.atttypid, a.atttypmod, a.attnotnull, a.attnum
        ORDER BY a.attnum
        """
        let res = try Database.execParams(conn, sql, [schema, table])
        return res.rows.compactMap { row in
            guard row.count >= 5, let name = row[0], let type = row[1] else { return nil }
            return ColumnInfo(
                name: name,
                type: type,
                notNull: (row[2] == "t"),
                isPK: (row[3] == "t"),
                isFK: (row[4] == "t")
            )
        }
    }

    /// A page of rows from a relation. Identifiers are quoted; `limit` caps the fetch.
    public func rows(database: String, schema: String, table: String, limit: Int = 200) throws -> RowSet {
        let conn = try connection(for: database)
        let sql = "SELECT * FROM \(Database.quoteIdent(schema)).\(Database.quoteIdent(table)) LIMIT \(max(0, limit))"
        let res = try Database.exec(conn, sql)
        return RowSet(columns: res.columns, rows: res.rows)
    }

    // MARK: - Raw libpq wrappers

    /// Quote a SQL identifier so it can be interpolated safely (doubles embedded quotes).
    private static func quoteIdent(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func rawConnect(_ cfg: Connection) throws -> OpaquePointer {
        var keywords: [String] = []
        var values: [String?] = []
        func add(_ k: String, _ v: String) {
            guard !v.isEmpty else { return }
            keywords.append(k); values.append(v)
        }
        add("host", cfg.host)
        add("port", cfg.port)
        add("dbname", cfg.database)
        add("user", cfg.user)
        add("password", cfg.password)
        add("sslmode", cfg.sslMode)
        add("connect_timeout", "8")
        add("application_name", "Tusk")

        let conn = withCStringArray(keywords.map { Optional($0) }) { kw in
            withCStringArray(values) { vv in
                PQconnectdbParams(kw, vv, 0)
            }
        }
        guard let conn else { throw PGError.message("Could not allocate connection.") }
        if PQstatus(conn) != CONNECTION_OK {
            let msg = String(cString: PQerrorMessage(conn)).trimmed
            PQfinish(conn)
            throw PGError.message(msg.isEmpty ? "Connection failed." : msg)
        }
        return conn
    }

    private static func exec(_ conn: OpaquePointer, _ sql: String) throws -> RawResult {
        guard let res = PQexec(conn, sql) else {
            throw PGError.message(String(cString: PQerrorMessage(conn)).trimmed)
        }
        defer { PQclear(res) }
        return try readResult(res)
    }

    private static func execParams(_ conn: OpaquePointer, _ sql: String, _ params: [String?]) throws -> RawResult {
        let res = withCStringArray(params) { valuesPtr -> OpaquePointer? in
            PQexecParams(conn, sql, Int32(params.count), nil, valuesPtr, nil, nil, 0)
        }
        guard let res else {
            throw PGError.message(String(cString: PQerrorMessage(conn)).trimmed)
        }
        defer { PQclear(res) }
        return try readResult(res)
    }

    private static func readResult(_ res: OpaquePointer) throws -> RawResult {
        let status = PQresultStatus(res)
        guard status == PGRES_TUPLES_OK || status == PGRES_COMMAND_OK else {
            let msg = String(cString: PQresultErrorMessage(res)).trimmed
            throw PGError.message(msg.isEmpty ? "Query failed." : msg)
        }
        let ncols = Int(PQnfields(res))
        let nrows = Int(PQntuples(res))
        var columns: [String] = []
        columns.reserveCapacity(ncols)
        for c in 0..<ncols {
            columns.append(String(cString: PQfname(res, Int32(c))))
        }
        var rows: [[String?]] = []
        rows.reserveCapacity(nrows)
        for r in 0..<nrows {
            var row: [String?] = []
            row.reserveCapacity(ncols)
            for c in 0..<ncols {
                if PQgetisnull(res, Int32(r), Int32(c)) == 1 {
                    row.append(nil)
                } else {
                    row.append(String(cString: PQgetvalue(res, Int32(r), Int32(c))))
                }
            }
            rows.append(row)
        }
        return RawResult(columns: columns, rows: rows)
    }
}
