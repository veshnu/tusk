import SwiftUI
import TuskCore

/// One open table in the center pane. `id` is "database|schema.name".
struct DataTab: Identifiable, Equatable {
    let id: String
    let database: String
    let relation: Relation
    var columns: [String] = []
    var columnInfos: [ColumnInfo] = []      // for header type badges / key glyphs
    var rows: [[String?]] = []
    var loading: Bool = true
    var error: String? = nil

    /// Column metadata keyed by name (type badge + PK/FK glyphs in the grid header).
    func info(for column: String) -> ColumnInfo? { columnInfos.first { $0.name == column } }

    static func makeID(database: String, relationID: String) -> String { "\(database)|\(relationID)" }
}

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

    // Live connection health, polled while connected ("connected" / "error" / "connecting").
    @Published var connectionStatus: String = "connecting"
    private var healthTask: Task<Void, Never>?

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

    // Open table tabs shown in the center pane (each double-click opens/focuses one).
    @Published var tabs: [DataTab] = []
    @Published var activeTabID: String?

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

    /// Open a connection, load the connected database's schema, and route into the
    /// workspace on success. Only the connected database is browsed — Tusk holds a
    /// single connection rather than one per database on the server.
    func connect(_ conn: Connection) {
        guard !connecting else { return }
        connecting = true
        connectError = nil
        Task {
            do {
                try await db.open(conn)
                let snap = try await db.snapshot(database: conn.database)
                activeConn = conn
                databases = [conn.database]
                snapshots = [conn.database: snap]
                expandedDatabases = [conn.database]
                databaseErrors = [:]
                selectedDatabase = conn.database
                route = .workspace
                connectionStatus = "connected"
                selectServer()
                startMCPServer(for: conn)
                startHealthMonitor()
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

    // MARK: Connection health

    /// Poll the live connection every few seconds and reflect it in `connectionStatus`.
    private func startHealthMonitor() {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let ok = await self.db.ping()
                if Task.isCancelled { return }
                self.connectionStatus = ok ? "connected" : "error"
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    private func stopHealthMonitor() {
        healthTask?.cancel()
        healthTask = nil
    }

    func disconnect() {
        stopMCPServer()
        stopHealthMonitor()
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
        tabs = []
        activeTabID = nil
        connectionStatus = "connecting"
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

    // MARK: Table tabs (double-click)

    /// Double-click a relation: select it, and open (or focus) a data tab for it.
    func openTable(database: String, relation: Relation) {
        select(database: database, relation: relation)
        let id = DataTab.makeID(database: database, relationID: relation.id)
        activeTabID = id
        if tabs.contains(where: { $0.id == id }) { return }   // already open — just focus it
        tabs.append(DataTab(id: id, database: database, relation: relation))
        loadRows(for: id, database: database, relation: relation)
    }

    /// Switch to an already-open tab and sync the inspector to its relation.
    func focusTab(_ id: String) {
        activeTabID = id
        if let tab = tabs.first(where: { $0.id == id }) {
            select(database: tab.database, relation: tab.relation)
        }
    }

    func closeTab(_ id: String) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: idx)
        Task { await db.closeTab(id) }   // release this tab's dedicated connection
        if activeTabID == id {
            let next = tabs[safe: idx] ?? tabs[safe: idx - 1]
            if let next { focusTab(next.id) } else { activeTabID = nil }
        }
    }

    /// Reload the rows for a tab (e.g. the toolbar refresh button).
    func reloadTab(_ id: String) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        loadRows(for: id, database: tab.database, relation: tab.relation)
    }

    private func loadRows(for id: String, database: String, relation: Relation) {
        updateTab(id) { $0.loading = true; $0.error = nil; $0.columns = []; $0.rows = [] }
        Task {
            do {
                let cols = try await db.tabColumns(tab: id, database: database, schema: relation.schema, table: relation.name)
                let set = try await db.tabRows(tab: id, database: database, schema: relation.schema, table: relation.name, limit: 200)
                updateTab(id) {
                    $0.columnInfos = cols
                    $0.columns = set.columns
                    $0.rows = set.rows
                    $0.loading = false
                }
            } catch {
                updateTab(id) { $0.error = error.localizedDescription; $0.loading = false }
            }
        }
    }

    /// Mutate a tab in place if it still exists (it may have been closed mid-load).
    private func updateTab(_ id: String, _ mutate: (inout DataTab) -> Void) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&tabs[idx])
    }

    private var selectionToken: String { "\(selectedDatabase ?? "")|\(selectedRelationID ?? "")" }

    var activeTab: DataTab? {
        guard let id = activeTabID else { return nil }
        return tabs.first { $0.id == id }
    }

    var selectedSnapshot: DBSnapshot? {
        guard let d = selectedDatabase else { return nil }
        return snapshots[d]
    }

    var selectedRelation: Relation? {
        selectedSnapshot?.relations.first { $0.id == selectedRelationID }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
