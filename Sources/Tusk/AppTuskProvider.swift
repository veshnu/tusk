import Foundation
import TuskCore

/// Backs the MCP tools with Tusk's live state: all configured connections (from
/// `ConnectionStore`) and the currently-open connection's databases/schema (from
/// `AppModel`). Tusk opens one connection at a time, so table/column lookups apply
/// to the active connection; other connections list but can't be drilled into until
/// opened in the app.
final class AppTuskProvider: TuskStateProviding, @unchecked Sendable {
    private let db: Database
    private weak var model: AppModel?
    private weak var store: ConnectionStore?

    init(model: AppModel, store: ConnectionStore) {
        self.db = model.db
        self.model = model
        self.store = store
    }

    func listConnections() async -> [ConnectionInfo] {
        await MainActor.run {
            let activeId = model?.activeConn?.id
            return (store?.connections ?? []).map { c in
                ConnectionInfo(id: c.id, name: c.name.isEmpty ? "Untitled" : c.name,
                               host: c.host, port: c.port, user: c.user, database: c.database,
                               env: c.env, status: c.id == activeId ? "connected" : "disconnected")
            }
        }
    }

    func listDatabases(connectionId: String) async throws -> [DatabaseInfo] {
        // Reflect Tusk's known state — no fresh server round-trip.
        let known: [String]? = await MainActor.run {
            guard model?.activeConn?.id == connectionId else { return nil }
            return model?.databases ?? []
        }
        if let known {
            return known.map { DatabaseInfo(id: TuskID.database(connectionId: connectionId, name: $0), name: $0, connectionId: connectionId) }
        }
        // Not the active connection: we only know its configured default database.
        let configured: Connection? = await MainActor.run { store?.connections.first { $0.id == connectionId } }
        guard let cfg = configured else { throw MCPError.notFound("connection \(connectionId)") }
        return [DatabaseInfo(id: TuskID.database(connectionId: connectionId, name: cfg.database), name: cfg.database, connectionId: connectionId)]
    }

    func listTables(databaseId: String) async throws -> [TableInfo] {
        let (connId, dbName) = try TuskID.splitDatabase(databaseId)
        try await requireActive(connId)
        // Prefer the schema Tusk already loaded; otherwise load it once.
        if let cached = await MainActor.run(body: { model?.snapshots[dbName] }) {
            return cached.relations.map(Self.tableInfo)
        }
        let snap = try await db.snapshot(database: dbName)
        return snap.relations.map(Self.tableInfo)
    }

    func describeTable(databaseId: String, tableId: String) async throws -> [ColumnInfo] {
        let (connId, dbName) = try TuskID.splitDatabase(databaseId)
        try await requireActive(connId)
        let (schema, table) = try TuskID.splitTable(tableId)
        return try await db.columns(database: dbName, schema: schema, table: table)
    }

    // MARK: Helpers

    private func requireActive(_ connectionId: String) async throws {
        let isActive = await MainActor.run { model?.activeConn?.id == connectionId }
        guard isActive else {
            throw MCPError.notConnected("Open this connection in Tusk to browse its tables.")
        }
    }

    private static func tableInfo(_ r: Relation) -> TableInfo {
        TableInfo(id: TuskID.table(schema: r.schema, name: r.name), name: r.name, schema: r.schema, kind: r.kind.rawValue)
    }
}
