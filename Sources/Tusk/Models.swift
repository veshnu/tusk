import Foundation

// MARK: - Connection

/// A saved Postgres connection. `password` is not persisted here — it lives in
/// the Keychain (see `Keychain`) when the user opts to save it.
struct Connection: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var host: String
    var port: String
    var database: String
    var user: String
    var sslMode: String
    var savePassword: Bool
    var env: String

    /// Not persisted to disk; loaded from Keychain or held transiently in memory.
    var password: String = ""

    enum CodingKeys: String, CodingKey {
        case id, name, host, port, database, user, sslMode, savePassword, env
    }

    var hostPort: String { "\(host):\(port)" }

    static func blank() -> Connection {
        Connection(name: "", host: "localhost", port: "5432", database: "postgres",
                   user: "postgres", sslMode: "prefer", savePassword: true, env: "local", password: "")
    }
}

// MARK: - Schema objects

enum DBObjectKind: String {
    case database, schema, table, view, matview, partitioned, function

    var iconName: String {
        switch self {
        case .database: return "cylinder"
        case .schema: return "shippingbox"
        case .table: return "tablecells"
        case .view: return "eye"
        case .matview: return "eye.square"
        case .partitioned: return "square.split.2x2"
        case .function: return "function"
        }
    }

    static func fromRelkind(_ k: String) -> DBObjectKind {
        switch k {
        case "r": return .table
        case "v": return .view
        case "m": return .matview
        case "p": return .partitioned
        default: return .table
        }
    }
}

/// A tree node in the schema explorer (database → schema → relation).
struct SchemaNode: Identifiable, Equatable {
    let id: String
    var label: String
    var kind: DBObjectKind
    var depth: Int
    var expandable: Bool
    var trailing: String?     // e.g. estimated row count "18.2k"
    var qualifiedName: String? // schema.relation, for querying columns
    var muted: Bool = false
}

/// A relation returned from pg_catalog.
struct Relation: Identifiable, Equatable {
    var id: String { "\(schema).\(name)" }
    let schema: String
    let name: String
    let kind: DBObjectKind
    let estRows: Int64
}

/// A column of a relation.
struct ColumnInfo: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let type: String
    let notNull: Bool
    let isPK: Bool
    let isFK: Bool
}

// MARK: - Formatting helpers

enum Fmt {
    /// Compact row count, e.g. 18234 -> "18.2k", 52000 -> "52k".
    static func rows(_ n: Int64) -> String {
        if n < 0 { return "0" }
        if n < 1000 { return "\(n)" }
        let thousands = Double(n) / 1000
        if n < 10_000 {
            return String(format: "%.1fk", thousands)
        }
        if n < 1_000_000 {
            return "\(Int(thousands.rounded()))k"
        }
        return String(format: "%.1fM", Double(n) / 1_000_000)
    }
}
