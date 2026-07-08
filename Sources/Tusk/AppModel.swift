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

    // Embedded Claude Code terminal (bottom-docked panel).
    @Published var showTerminal = false
    let terminal = TerminalController()

    func toggleTerminal() { showTerminal.toggle() }

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

    // Open tabs shown in the center pane: table data (double-click) or query consoles.
    @Published var tabs: [WorkspaceTab] = []
    @Published var activeTabID: String?

    // Column cache for SQL completion, keyed "database|schema.table".
    private var columnCache: [String: [ColumnInfo]] = [:]
    private var prefetchedColumnDBs: Set<String> = []
    private var persistTask: Task<Void, Never>?

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
                restoreConsoles(for: conn.id)
                prefetchColumns(database: conn.database)
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
        persistTask?.cancel()
        flushConsolePersist()   // keep the console index/files for next time
        Task { await db.close() }
        activeConn = nil
        databases = []
        snapshots = [:]
        expandedDatabases = []
        loadingDatabases = []
        databaseErrors = [:]
        columns = []
        columnCache = [:]
        prefetchedColumnDBs = []
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
                columnCache["\(database)|\(relation.schema).\(relation.name)"] = cols
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
        tabs.append(.data(DataTab(id: id, database: database, relation: relation)))
        loadRows(for: id, database: database, relation: relation)
    }

    /// Switch to an already-open tab and sync the inspector to its subject.
    func focusTab(_ id: String) {
        activeTabID = id
        switch tabs.first(where: { $0.id == id }) {
        case .data(let t):     select(database: t.database, relation: t.relation)
        case .console(let c):  inspector = .database(c.database); selectedDatabase = c.database; selectedRelationID = nil
        case nil:              break
        }
        scheduleConsolePersist()   // remember the selected console for restore
    }

    func closeTab(_ id: String) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closing = tabs[idx]
        tabs.remove(at: idx)
        Task {
            if closing.asConsole != nil { await db.closeConsole(id) } else { await db.closeTab(id) }
        }
        if closing.asConsole != nil {
            ConsoleStore.remove(id: id)
            scheduleConsolePersist()
        }
        if activeTabID == id {
            let next = tabs[safe: idx] ?? tabs[safe: idx - 1]
            if let next { focusTab(next.id) } else { activeTabID = nil }
        }
    }

    /// Reload the rows for a data tab (e.g. the toolbar refresh button).
    func reloadTab(_ id: String) {
        guard case .data(let tab)? = tabs.first(where: { $0.id == id }) else { return }
        loadRows(for: id, database: tab.database, relation: tab.relation)
    }

    private func loadRows(for id: String, database: String, relation: Relation) {
        updateDataTab(id) { $0.loading = true; $0.error = nil; $0.columns = []; $0.rows = [] }
        Task {
            do {
                let cols = try await db.tabColumns(tab: id, database: database, schema: relation.schema, table: relation.name)
                let set = try await db.tabRows(tab: id, database: database, schema: relation.schema, table: relation.name, limit: 200)
                columnCache["\(database)|\(relation.schema).\(relation.name)"] = cols
                updateDataTab(id) {
                    $0.columnInfos = cols
                    $0.columns = set.columns
                    $0.rows = set.rows
                    $0.loading = false
                }
            } catch {
                updateDataTab(id) { $0.error = error.localizedDescription; $0.loading = false }
            }
        }
    }

    /// Mutate a data tab in place if it still exists (it may have been closed mid-load).
    private func updateDataTab(_ id: String, _ mutate: (inout DataTab) -> Void) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }), case .data(var t) = tabs[idx] else { return }
        mutate(&t)
        tabs[idx] = .data(t)
    }

    /// Mutate a console in place if it still exists.
    private func updateConsole(_ id: String, _ mutate: (inout QueryConsole) -> Void) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }), case .console(var c) = tabs[idx] else { return }
        mutate(&c)
        tabs[idx] = .console(c)
    }

    private var selectionToken: String { "\(selectedDatabase ?? "")|\(selectedRelationID ?? "")" }

    var activeTab: WorkspaceTab? {
        guard let id = activeTabID else { return nil }
        return tabs.first { $0.id == id }
    }

    var activeConsole: QueryConsole? { activeTab?.asConsole }
    func console(_ id: String) -> QueryConsole? { tabs.first { $0.id == id }?.asConsole }
    var consoles: [QueryConsole] { tabs.compactMap { $0.asConsole } }

    // MARK: Query consoles

    /// Open a new query console bound to `database` (on `connectionId`, defaulting to
    /// the active connection). Seeds the buffer with `seedSQL` and focuses the tab.
    @discardableResult
    func openConsole(connectionId: String? = nil, database: String, seedSQL: String? = nil) -> String {
        let connId = connectionId ?? activeConn?.id ?? ""
        let id = QueryConsole.newID()
        let sql = seedSQL ?? ""
        let console = QueryConsole(id: id, connectionId: connId, database: database,
                                   title: QueryConsole.deriveTitle(sql: sql), sql: sql)
        tabs.append(.console(console))
        activeTabID = id
        inspector = .database(database)
        selectedDatabase = database
        selectedRelationID = nil
        ConsoleStore.writeSQL(id: id, sql: sql)
        flushConsolePersist()
        prefetchColumns(database: database)
        return id
    }

    /// Replace a console's SQL buffer (human keystrokes or an MCP edit). Updates the
    /// derived title and mirrors to disk (debounced).
    func setConsoleSQL(_ id: String, sql: String) {
        updateConsole(id) { $0.sql = sql; $0.title = QueryConsole.deriveTitle(sql: sql) }
        scheduleConsolePersist()
    }

    /// Toggle a console's read-only posture (writes rejected by the server).
    func setConsoleReadOnly(_ id: String, _ readOnly: Bool) {
        updateConsole(id) { $0.readOnly = readOnly }
        scheduleConsolePersist()
    }

    /// Run a console's SQL on its dedicated lane (UI Run button).
    func runConsole(_ id: String) {
        Task { await runConsoleAwait(id, byClaude: false) }
    }

    /// Run and await completion — used by MCP so it can return the results.
    func runConsoleAwait(_ id: String, byClaude: Bool) async {
        guard let c = console(id) else { return }
        updateConsole(id) { $0.running = true; $0.error = nil; $0.lastRunByClaude = byClaude }
        let start = DispatchTime.now()
        do {
            let set = try await db.runConsole(id, database: c.database, sql: c.sql, readOnly: c.readOnly)
            let ms = Int(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
            updateConsole(id) {
                $0.columns = set.columns; $0.rows = set.rows
                $0.running = false; $0.error = nil; $0.elapsedMs = ms
            }
        } catch {
            updateConsole(id) { $0.running = false; $0.error = error.localizedDescription; $0.elapsedMs = nil }
        }
    }

    /// The schema data a console completes against, for `database`.
    func schemaIndex(for database: String) -> SchemaIndex {
        var idx = SchemaIndex()
        if let snap = snapshots[database] {
            idx.tables = snap.relations.map { .init(name: $0.name, schema: $0.schema, kind: $0.kind.rawValue) }
        }
        for (key, cols) in columnCache where key.hasPrefix("\(database)|") {
            let qualified = String(key.dropFirst(database.count + 1))   // "schema.table"
            let mapped = cols.map { SchemaIndex.Col(name: $0.name, type: $0.type, pk: $0.isPK, fk: $0.isFK) }
            idx.columnsByTable[qualified.lowercased()] = mapped
            if let dot = qualified.firstIndex(of: ".") {
                let bare = String(qualified[qualified.index(after: dot)...])
                idx.columnsByTable[bare.lowercased()] = mapped
            }
        }
        return idx
    }

    /// Warm the column cache for a database (background) so dot-completion works.
    private func prefetchColumns(database: String) {
        guard !prefetchedColumnDBs.contains(database), let snap = snapshots[database] else { return }
        prefetchedColumnDBs.insert(database)
        let targets = Array(snap.relations.prefix(150))   // cap: huge schemas load lazily via selection
        Task {
            for rel in targets {
                let key = "\(database)|\(rel.schema).\(rel.name)"
                if columnCache[key] != nil { continue }
                if let cols = try? await db.columns(database: database, schema: rel.schema, table: rel.name) {
                    columnCache[key] = cols
                }
            }
        }
    }

    // MARK: Console persistence (write-through, debounced)

    private func scheduleConsolePersist() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled else { return }
            self.flushConsolePersist()
        }
    }

    private func flushConsolePersist() {
        let cs = consoles
        for c in cs { ConsoleStore.writeSQL(id: c.id, sql: c.sql) }
        ConsoleStore.writeIndex(consoles: cs, selected: activeTabID)
    }

    private func restoreConsoles(for connectionId: String) {
        let (restored, selected) = ConsoleStore.restore(connectionId: connectionId)
        guard !restored.isEmpty else { return }
        for c in restored { tabs.append(.console(c)) }
        if let selected { activeTabID = selected }
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
