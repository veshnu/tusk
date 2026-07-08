import Foundation

// MARK: - DTOs returned to MCP clients

public struct ConnectionInfo: Sendable {
    public let id: String
    public let name: String
    public let host: String
    public let port: String
    public let user: String
    public let database: String   // the connection's default database
    public let env: String
    public let status: String     // "connected" | "disconnected"

    public init(id: String, name: String, host: String, port: String, user: String,
                database: String, env: String, status: String) {
        self.id = id; self.name = name; self.host = host; self.port = port
        self.user = user; self.database = database; self.env = env; self.status = status
    }
}

public struct DatabaseInfo: Sendable {
    public let id: String          // "{connectionId}/{name}"
    public let name: String
    public let connectionId: String

    public init(id: String, name: String, connectionId: String) {
        self.id = id; self.name = name; self.connectionId = connectionId
    }
}

public struct TableInfo: Sendable {
    public let id: String          // "{schema}.{name}"
    public let name: String
    public let schema: String
    public let kind: String        // table / view / matview / ...

    public init(id: String, name: String, schema: String, kind: String) {
        self.id = id; self.name = name; self.schema = schema; self.kind = kind
    }
}

/// A query console open in the app (summary form, for `list_query_consoles`).
public struct ConsoleInfo: Sendable {
    public let id: String
    public let database: String     // database name the console runs against
    public let title: String
    public let selected: Bool       // is this the focused tab?

    public init(id: String, database: String, title: String, selected: Bool) {
        self.id = id; self.database = database; self.title = title; self.selected = selected
    }
}

/// A query console's full state: its SQL buffer and latest results.
public struct ConsoleDetail: Sendable {
    public let id: String
    public let database: String
    public let title: String
    public let sql: String
    public let columns: [String]
    public let rows: [[String?]]
    public let error: String?
    public let running: Bool

    public init(id: String, database: String, title: String, sql: String,
                columns: [String], rows: [[String?]], error: String?, running: Bool) {
        self.id = id; self.database = database; self.title = title; self.sql = sql
        self.columns = columns; self.rows = rows; self.error = error; self.running = running
    }
}

// MARK: - ID helpers

public enum TuskID {
    public static func database(connectionId: String, name: String) -> String { "\(connectionId)/\(name)" }
    public static func table(schema: String, name: String) -> String { "\(schema).\(name)" }

    /// Split "{connectionId}/{db}" on the first slash.
    public static func splitDatabase(_ id: String) throws -> (connectionId: String, database: String) {
        guard let slash = id.firstIndex(of: "/") else {
            throw MCPError.invalidArguments("database_id must look like \"<connection_id>/<database>\"")
        }
        return (String(id[..<slash]), String(id[id.index(after: slash)...]))
    }

    /// Split "{schema}.{table}" on the first dot.
    public static func splitTable(_ id: String) throws -> (schema: String, table: String) {
        guard let dot = id.firstIndex(of: ".") else {
            throw MCPError.invalidArguments("table_id must look like \"<schema>.<table>\"")
        }
        return (String(id[..<dot]), String(id[id.index(after: dot)...]))
    }
}

// MARK: - Provider

/// The state the MCP tools read. The GUI implements this over its live connections;
/// the CLI implements a single-connection version for headless use.
public protocol TuskStateProviding: Sendable {
    func listConnections() async -> [ConnectionInfo]
    func listDatabases(connectionId: String) async throws -> [DatabaseInfo]
    func listTables(databaseId: String) async throws -> [TableInfo]
    func describeTable(databaseId: String, tableId: String) async throws -> [ColumnInfo]

    // Query consoles — driving Tusk's GUI from MCP. Only the app-backed provider
    // implements these; the headless CLI has no window to open consoles in.
    func createQueryConsole(databaseId: String, sql: String?) async throws -> String
    func listQueryConsoles() async -> [ConsoleInfo]
    func selectedQueryConsole() async -> String?
    func selectQueryConsole(consoleId: String) async throws
    func getQueryConsole(consoleId: String) async throws -> ConsoleDetail
    func setQueryConsoleSQL(consoleId: String, sql: String) async throws -> ConsoleDetail
    func runQueryConsole(consoleId: String) async throws -> ConsoleDetail
}

/// Default console methods: unsupported unless a GUI-backed provider overrides them.
public extension TuskStateProviding {
    private var noConsoles: MCPError { .notConnected("Query consoles require the Tusk app to be running.") }

    func createQueryConsole(databaseId: String, sql: String?) async throws -> String { throw noConsoles }
    func listQueryConsoles() async -> [ConsoleInfo] { [] }
    func selectedQueryConsole() async -> String? { nil }
    func selectQueryConsole(consoleId: String) async throws { throw noConsoles }
    func getQueryConsole(consoleId: String) async throws -> ConsoleDetail { throw noConsoles }
    func setQueryConsoleSQL(consoleId: String, sql: String) async throws -> ConsoleDetail { throw noConsoles }
    func runQueryConsole(consoleId: String) async throws -> ConsoleDetail { throw noConsoles }
}

// MARK: - Headless provider (single connection, for `tusk mcp` without the app)

public final class EnvTuskProvider: TuskStateProviding, @unchecked Sendable {
    private let db: Database
    private let connection: Connection

    public init(db: Database, connection: Connection) {
        self.db = db
        self.connection = connection
    }

    public func listConnections() async -> [ConnectionInfo] {
        [ConnectionInfo(id: connection.id, name: connection.name.isEmpty ? "env" : connection.name,
                        host: connection.host, port: connection.port, user: connection.user,
                        database: connection.database, env: connection.env, status: "connected")]
    }

    public func listDatabases(connectionId: String) async throws -> [DatabaseInfo] {
        guard connectionId == connection.id else { throw MCPError.notFound("connection \(connectionId)") }
        let names = try await db.databases()
        return names.map { DatabaseInfo(id: TuskID.database(connectionId: connectionId, name: $0), name: $0, connectionId: connectionId) }
    }

    public func listTables(databaseId: String) async throws -> [TableInfo] {
        let (connId, dbName) = try TuskID.splitDatabase(databaseId)
        guard connId == connection.id else { throw MCPError.notFound("connection \(connId)") }
        let snap = try await db.snapshot(database: dbName)
        return snap.relations.map {
            TableInfo(id: TuskID.table(schema: $0.schema, name: $0.name), name: $0.name, schema: $0.schema, kind: $0.kind.rawValue)
        }
    }

    public func describeTable(databaseId: String, tableId: String) async throws -> [ColumnInfo] {
        let (connId, dbName) = try TuskID.splitDatabase(databaseId)
        guard connId == connection.id else { throw MCPError.notFound("connection \(connId)") }
        let (schema, table) = try TuskID.splitTable(tableId)
        return try await db.columns(database: dbName, schema: schema, table: table)
    }
}
