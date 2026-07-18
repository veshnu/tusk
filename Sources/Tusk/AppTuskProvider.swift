import Foundation
import TuskCore

/// Backs the MCP tools with Tusk's live state: all configured connections (from
/// `ConnectionStore`) and the databases/schema of any *currently-connected* one
/// (from `AppModel.sessions`). Several connections can be live at once; each
/// table/column lookup routes to the owning connection's libpq manager. Connections
/// that aren't connected list but can't be drilled into until opened in the app.
final class AppTuskProvider: TuskStateProviding, @unchecked Sendable {
    private weak var model: AppModel?
    private weak var store: ConnectionStore?

    init(model: AppModel, store: ConnectionStore) {
        self.model = model
        self.store = store
    }

    func listConnections() async -> [ConnectionInfo] {
        await MainActor.run {
            (store?.connections ?? []).map { c in
                ConnectionInfo(id: c.id, name: c.name.isEmpty ? "Untitled" : c.name,
                               host: c.host, port: c.port, user: c.user, database: c.database,
                               env: c.env, status: model?.isConnected(c.id) == true ? "connected" : "disconnected")
            }
        }
    }

    func listDatabases(connectionId: String) async throws -> [DatabaseInfo] {
        // Reflect Tusk's known state — no fresh server round-trip.
        let known: [String]? = await MainActor.run {
            model?.isConnected(connectionId) == true ? model?.session(connectionId)?.databases : nil
        }
        if let known {
            return known.map { DatabaseInfo(id: TuskID.database(connectionId: connectionId, name: $0), name: $0, connectionId: connectionId) }
        }
        // Not connected: we only know its configured default database.
        let configured: Connection? = await MainActor.run { store?.connections.first { $0.id == connectionId } }
        guard let cfg = configured else { throw MCPError.notFound("connection \(connectionId)") }
        return [DatabaseInfo(id: TuskID.database(connectionId: connectionId, name: cfg.database), name: cfg.database, connectionId: connectionId)]
    }

    func listTables(databaseId: String) async throws -> [TableInfo] {
        let (connId, dbName) = try TuskID.splitDatabase(databaseId)
        let db = try await requireConnected(connId)
        // Prefer the schema Tusk already loaded; otherwise load it once.
        if let cached = await MainActor.run(body: { model?.session(connId)?.snapshots[dbName] }) {
            return cached.relations.map(Self.tableInfo)
        }
        let snap = try await db.snapshot(database: dbName)
        return snap.relations.map(Self.tableInfo)
    }

    func describeTable(databaseId: String, tableId: String) async throws -> [ColumnInfo] {
        let (connId, dbName) = try TuskID.splitDatabase(databaseId)
        let db = try await requireConnected(connId)
        let (schema, table) = try TuskID.splitTable(tableId)
        return try await db.columns(database: dbName, schema: schema, table: table)
    }

    // MARK: Query consoles (driving the GUI from MCP)

    func createQueryConsole(databaseId: String, sql: String?) async throws -> String {
        let (connId, dbName) = try TuskID.splitDatabase(databaseId)
        _ = try await requireConnected(connId)
        let id = await MainActor.run { model?.openConsole(connectionId: connId, database: dbName, seedSQL: sql) }
        guard let id else { throw MCPError.notConnected("Tusk is not running.") }
        return id
    }

    func listQueryConsoles() async -> [ConsoleInfo] {
        await MainActor.run {
            let sel = model?.activeConsole?.id
            return (model?.consoles ?? []).map {
                ConsoleInfo(id: $0.id, database: $0.database, title: $0.title, selected: $0.id == sel)
            }
        }
    }

    func selectedQueryConsole() async -> String? {
        await MainActor.run { model?.activeConsole?.id }
    }

    func selectQueryConsole(consoleId: String) async throws {
        try await MainActor.run {
            guard let model, model.console(consoleId) != nil else { throw MCPError.notFound("query console \(consoleId)") }
            model.focusTab(consoleId)
        }
    }

    func getQueryConsole(consoleId: String) async throws -> ConsoleDetail {
        try await detail(consoleId)
    }

    func setQueryConsoleSQL(consoleId: String, sql: String) async throws -> ConsoleDetail {
        try await MainActor.run {
            guard let model, model.console(consoleId) != nil else { throw MCPError.notFound("query console \(consoleId)") }
            model.setConsoleSQL(consoleId, sql: sql)
        }
        return try await detail(consoleId)
    }

    func runQueryConsole(consoleId: String) async throws -> ConsoleDetail {
        let exists = await MainActor.run { model?.console(consoleId) != nil }
        guard exists else { throw MCPError.notFound("query console \(consoleId)") }
        guard let model else { throw MCPError.notConnected("Tusk is not running.") }
        await model.runConsoleAwait(consoleId, byClaude: true)
        return try await detail(consoleId)
    }

    /// Build the DTO from the live console (full rows; the session caps for transport).
    private func detail(_ id: String) async throws -> ConsoleDetail {
        try await MainActor.run {
            guard let c = model?.console(id) else { throw MCPError.notFound("query console \(id)") }
            return ConsoleDetail(id: c.id, database: c.database, title: c.title, sql: c.sql,
                                 columns: c.columns, rows: c.rows, error: c.error, running: c.running)
        }
    }

    // MARK: Helpers

    /// Ensure the connection is currently connected and return its libpq manager.
    @discardableResult
    private func requireConnected(_ connectionId: String) async throws -> Database {
        let db = await MainActor.run { model?.isConnected(connectionId) == true ? model?.db(for: connectionId) : nil }
        guard let db else {
            throw MCPError.notConnected("Open this connection in Tusk to browse its tables.")
        }
        return db
    }

    private static func tableInfo(_ r: Relation) -> TableInfo {
        TableInfo(id: TuskID.table(schema: r.schema, name: r.name), name: r.name, schema: r.schema, kind: r.kind.rawValue)
    }
}
