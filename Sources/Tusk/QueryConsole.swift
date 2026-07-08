import Foundation
import TuskCore

// MARK: - Query console model

/// A SQL query console open in the center pane. Its SQL buffer is the source of
/// truth in memory; a `.sql` file under `TuskPaths.consolesDir` is a durable
/// mirror so consoles survive relaunch. Each console runs on its own dedicated
/// connection lane (keyed by `id`) bound to `database`.
struct QueryConsole: Identifiable, Equatable {
    let id: String                 // UUID string; also the .sql filename stem
    let connectionId: String       // the connection this console belongs to
    let database: String           // database name the console runs against
    var title: String
    var sql: String

    // Latest run
    var columns: [String] = []
    var rows: [[String?]] = []
    var running: Bool = false
    var error: String? = nil
    var elapsedMs: Int? = nil
    var lastRunByClaude: Bool = false   // attribution: the last run was triggered over MCP
    var readOnly: Bool = false          // when set, the lane runs in a read-only transaction

    static func newID() -> String { UUID().uuidString }

    /// A short human title from the SQL, else "Query".
    static func deriveTitle(sql: String) -> String {
        let firstLine = sql.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if firstLine.isEmpty { return "Query" }
        return String(firstLine.prefix(28))
    }
}

// MARK: - Workspace tab (a tab is either table data or a query console)

/// One tab in the center pane. `DataTab` (a table opened by double-click) and
/// `QueryConsole` are distinct value types; this enum lets them share the tab bar
/// without either pretending to be the other.
enum WorkspaceTab: Identifiable, Equatable {
    case data(DataTab)
    case console(QueryConsole)

    var id: String {
        switch self {
        case .data(let t): return t.id
        case .console(let c): return c.id
        }
    }

    var asConsole: QueryConsole? {
        if case .console(let c) = self { return c }
        return nil
    }

    var asData: DataTab? {
        if case .data(let t) = self { return t }
        return nil
    }
}

// MARK: - On-disk persistence

/// A restore-index entry describing one open console (its buffer lives in `<id>.sql`).
private struct ConsoleIndexEntry: Codable {
    let id: String
    let connectionId: String
    let database: String
    let title: String
    var readOnly: Bool = false
}

private struct ConsoleIndex: Codable {
    var selected: String?
    var consoles: [ConsoleIndexEntry] = []
}

/// File-backed persistence for query consoles. All I/O is best-effort: a failure
/// to write never blocks the console (it keeps working in memory this session),
/// it only forfeits restore — same posture as the MCP-socket start.
enum ConsoleStore {
    static var dir: URL { URL(fileURLWithPath: TuskPaths.consolesDir, isDirectory: true) }
    static func fileURL(id: String) -> URL { dir.appendingPathComponent("\(id).sql") }
    private static var indexURL: URL { dir.appendingPathComponent("index.json") }

    private static func ensureDir() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Write one console's SQL buffer to its `.sql` file.
    static func writeSQL(id: String, sql: String) {
        ensureDir()
        do { try sql.data(using: .utf8)?.write(to: fileURL(id: id), options: .atomic) }
        catch { NSLog("Tusk: couldn't persist console \(id): \(error.localizedDescription)") }
    }

    /// Remove a console's `.sql` file (on close).
    static func remove(id: String) {
        try? FileManager.default.removeItem(at: fileURL(id: id))
    }

    /// Persist the set of open consoles + the selected one for restore.
    static func writeIndex(consoles: [QueryConsole], selected: String?) {
        ensureDir()
        let idx = ConsoleIndex(
            selected: selected,
            consoles: consoles.map {
                ConsoleIndexEntry(id: $0.id, connectionId: $0.connectionId,
                                  database: $0.database, title: $0.title, readOnly: $0.readOnly)
            }
        )
        do { try JSONEncoder().encode(idx).write(to: indexURL, options: .atomic) }
        catch { NSLog("Tusk: couldn't persist console index: \(error.localizedDescription)") }
    }

    /// Restore the consoles saved for a given connection (their buffers read back
    /// from disk). Consoles for other connections are left untouched on disk.
    /// Returns the restored consoles and which one was selected (if it's among them).
    static func restore(connectionId: String) -> (consoles: [QueryConsole], selected: String?) {
        guard let data = try? Data(contentsOf: indexURL),
              let idx = try? JSONDecoder().decode(ConsoleIndex.self, from: data) else {
            return ([], nil)
        }
        var restored: [QueryConsole] = []
        for entry in idx.consoles where entry.connectionId == connectionId {
            let sql = (try? String(contentsOf: fileURL(id: entry.id), encoding: .utf8)) ?? ""
            restored.append(QueryConsole(id: entry.id, connectionId: entry.connectionId,
                                         database: entry.database, title: entry.title,
                                         sql: sql, readOnly: entry.readOnly))
        }
        let selected = restored.contains(where: { $0.id == idx.selected }) ? idx.selected : restored.first?.id
        return (restored, selected)
    }
}
