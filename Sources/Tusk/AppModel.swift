import SwiftUI
import TuskCore

@MainActor
final class AppModel: ObservableObject {
    enum Route { case connect, workspace }

    @Published var route: Route = .connect
    @Published var isDark: Bool = false

    // Active session
    @Published var activeConn: Connection?

    // Server → databases → schemas → relations.
    // Databases are enumerated on connect; each database's relations are loaded
    // lazily the first time its node is expanded.
    @Published var databases: [String] = []
    @Published var snapshots: [String: DBSnapshot] = [:]
    @Published var expandedDatabases: Set<String> = []
    @Published var loadingDatabases: Set<String> = []
    @Published var databaseErrors: [String: String] = [:]

    // Transient UI state
    @Published var connecting = false
    @Published var connectError: String?
    @Published var loadingSchema = false
    @Published var schemaError: String?

    // Selected relation in the workspace + its columns
    @Published var selectedDatabase: String?
    @Published var selectedRelationID: String?      // "schema.name" within selectedDatabase
    @Published var columns: [ColumnInfo] = []
    @Published var loadingColumns = false

    let db = Database()

    /// MCP server hosting the live connection over the app's unix socket.
    private var mcpServer: MCPSocketServer?

    var palette: Palette { Palette(isDark: isDark) }

    func toggleTheme() { isDark.toggle() }

    /// The server root label in the explorer, e.g. "postgres@localhost".
    var serverLabel: String {
        guard let c = activeConn else { return "server" }
        return "\(c.user)@\(c.host)"
    }

    /// Open a connection, enumerate databases, load the connected database's schema,
    /// and route into the workspace on success.
    func connect(_ conn: Connection) {
        guard !connecting else { return }
        connecting = true
        connectError = nil
        Task {
            do {
                try await db.open(conn)
                let dbs = try await db.databases()
                let snap = try await db.snapshot(database: conn.database)
                activeConn = conn
                databases = dbs.contains(conn.database) ? dbs : ([conn.database] + dbs)
                snapshots = [conn.database: snap]
                expandedDatabases = [conn.database]
                databaseErrors = [:]
                selectedDatabase = conn.database
                route = .workspace
                selectFirstRelation(in: conn.database)
                startMCPServer(for: conn)
            } catch {
                connectError = error.localizedDescription
            }
            connecting = false
        }
    }

    /// Toggle a database node; load its schema on first expand.
    func toggleDatabase(_ database: String) {
        if expandedDatabases.contains(database) {
            expandedDatabases.remove(database)
        } else {
            expandedDatabases.insert(database)
            loadDatabase(database)
        }
    }

    private func loadDatabase(_ database: String) {
        guard snapshots[database] == nil, !loadingDatabases.contains(database) else { return }
        loadingDatabases.insert(database)
        databaseErrors[database] = nil
        Task {
            do { snapshots[database] = try await db.snapshot(database: database) }
            catch { databaseErrors[database] = error.localizedDescription }
            loadingDatabases.remove(database)
        }
    }

    func refreshSchema() {
        guard activeConn != nil else { return }
        let loaded = Array(snapshots.keys)
        loadingSchema = true
        schemaError = nil
        Task {
            do {
                databases = try await db.databases()
                for d in loaded { snapshots[d] = try await db.snapshot(database: d) }
            } catch { schemaError = error.localizedDescription }
            loadingSchema = false
        }
    }

    // MARK: MCP server lifecycle

    private func startMCPServer(for conn: Connection) {
        mcpServer?.stop()
        let server = MCPSocketServer(db: db, connection: conn)
        do {
            try server.start()
            mcpServer = server
        } catch {
            // Non-fatal: the GUI keeps working even if the socket can't be hosted.
            NSLog("Tusk: failed to start MCP server: \(error.localizedDescription)")
        }
    }

    private func stopMCPServer() {
        mcpServer?.stop()
        mcpServer = nil
    }

    func disconnect() {
        stopMCPServer()
        Task { await db.close() }
        activeConn = nil
        databases = []
        snapshots = [:]
        expandedDatabases = []
        loadingDatabases = []
        databaseErrors = [:]
        columns = []
        selectedDatabase = nil
        selectedRelationID = nil
        route = .connect
    }

    // MARK: Relation selection

    private func selectFirstRelation(in database: String) {
        if let first = snapshots[database]?.relations.first {
            select(database: database, relation: first)
        }
    }

    func select(database: String, relation: Relation) {
        selectedDatabase = database
        selectedRelationID = relation.id
        loadingColumns = true
        columns = []
        let token = selectionToken
        Task {
            do {
                let cols = try await db.columns(database: database, schema: relation.schema, table: relation.name)
                if selectionToken == token { columns = cols }
            } catch {
                if selectionToken == token { columns = [] }
            }
            loadingColumns = false
        }
    }

    private var selectionToken: String { "\(selectedDatabase ?? "")|\(selectedRelationID ?? "")" }

    var selectedSnapshot: DBSnapshot? {
        guard let d = selectedDatabase else { return nil }
        return snapshots[d]
    }

    var selectedRelation: Relation? {
        selectedSnapshot?.relations.first { $0.id == selectedRelationID }
    }
}
