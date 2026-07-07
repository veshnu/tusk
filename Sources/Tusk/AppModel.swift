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

    /// What the right-hand inspector rail is describing. Driven by single-clicks in the tree.
    enum Inspector: Equatable {
        case server
        case database(String)
        case relation
    }
    @Published var inspector: Inspector = .server

    // Selected relation in the workspace + its columns (shown in the inspector).
    @Published var selectedDatabase: String?
    @Published var selectedRelationID: String?      // "schema.name" within selectedDatabase
    @Published var columns: [ColumnInfo] = []
    @Published var loadingColumns = false

    // Opened table data shown in the center pane (driven by double-click).
    @Published var openedDatabase: String?
    @Published var openedRelationID: String?
    @Published var dataColumns: [String] = []
    @Published var dataRows: [[String?]] = []
    @Published var loadingData = false
    @Published var dataError: String?

    let db = Database()

    /// Set once at launch; lets the MCP provider enumerate all configured connections.
    weak var connectionStore: ConnectionStore?

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
                selectServer()
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
        guard let store = connectionStore else { return }
        mcpServer?.stop()
        let provider = AppTuskProvider(model: self, store: store)
        let server = MCPSocketServer(provider: provider)
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
        inspector = .server
        openedDatabase = nil
        openedRelationID = nil
        dataColumns = []
        dataRows = []
        dataError = nil
        route = .connect
    }

    // MARK: Inspector selection (single-click)

    /// Single-click the server node: describe the connection in the inspector.
    func selectServer() {
        inspector = .server
        selectedRelationID = nil
    }

    /// Single-click a database node: describe the database (loading its snapshot for stats).
    func selectDatabase(_ database: String) {
        inspector = .database(database)
        selectedDatabase = database
        selectedRelationID = nil
        loadDatabase(database)
    }

    /// Single-click a relation: describe it (its columns) in the inspector.
    func select(database: String, relation: Relation) {
        inspector = .relation
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

    // MARK: Table data (double-click)

    /// Double-click a relation: select it *and* load a page of its rows into the center pane.
    func openTable(database: String, relation: Relation) {
        select(database: database, relation: relation)
        openedDatabase = database
        openedRelationID = relation.id
        loadingData = true
        dataError = nil
        dataColumns = []
        dataRows = []
        let token = "\(database)|\(relation.id)"
        Task {
            do {
                let set = try await db.rows(database: database, schema: relation.schema, table: relation.name, limit: 200)
                if openToken == token { dataColumns = set.columns; dataRows = set.rows }
            } catch {
                if openToken == token { dataError = error.localizedDescription }
            }
            loadingData = false
        }
    }

    private var selectionToken: String { "\(selectedDatabase ?? "")|\(selectedRelationID ?? "")" }
    private var openToken: String { "\(openedDatabase ?? "")|\(openedRelationID ?? "")" }

    var selectedSnapshot: DBSnapshot? {
        guard let d = selectedDatabase else { return nil }
        return snapshots[d]
    }

    var selectedRelation: Relation? {
        selectedSnapshot?.relations.first { $0.id == selectedRelationID }
    }

    /// The relation whose data is open in the center pane, if any.
    var openedRelation: Relation? {
        guard let d = openedDatabase, let id = openedRelationID else { return nil }
        return snapshots[d]?.relations.first { $0.id == id }
    }
}
