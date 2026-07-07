import Foundation

// MARK: - Connection

/// A saved Postgres connection. `password` is not persisted here — it lives in
/// the Keychain (see `Keychain`) when the user opts to save it.
public struct Connection: Identifiable, Codable, Equatable, Sendable {
    public var id: String = UUID().uuidString
    public var name: String
    public var host: String
    public var port: String
    public var database: String
    public var user: String
    public var sslMode: String
    public var savePassword: Bool
    public var env: String

    /// Not persisted to disk; loaded from Keychain or held transiently in memory.
    public var password: String = ""

    enum CodingKeys: String, CodingKey {
        case id, name, host, port, database, user, sslMode, savePassword, env
    }

    public init(id: String = UUID().uuidString, name: String, host: String, port: String,
                database: String, user: String, sslMode: String, savePassword: Bool,
                env: String, password: String = "") {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.database = database
        self.user = user
        self.sslMode = sslMode
        self.savePassword = savePassword
        self.env = env
        self.password = password
    }

    public var hostPort: String { "\(host):\(port)" }

    public static func blank() -> Connection {
        Connection(name: "", host: "localhost", port: "5432", database: "postgres",
                   user: "postgres", sslMode: "prefer", savePassword: true, env: "local", password: "")
    }
}

// MARK: - Schema objects

public enum DBObjectKind: String, Sendable {
    case database, schema, table, view, matview, partitioned, function

    public var iconName: String {
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

    public static func fromRelkind(_ k: String) -> DBObjectKind {
        switch k {
        case "r": return .table
        case "v": return .view
        case "m": return .matview
        case "p": return .partitioned
        default: return .table
        }
    }
}

/// A relation returned from pg_catalog.
public struct Relation: Identifiable, Equatable, Sendable {
    public var id: String { "\(schema).\(name)" }
    public let schema: String
    public let name: String
    public let kind: DBObjectKind
    public let estRows: Int64

    public init(schema: String, name: String, kind: DBObjectKind, estRows: Int64) {
        self.schema = schema
        self.name = name
        self.kind = kind
        self.estRows = estRows
    }
}

/// A column of a relation.
public struct ColumnInfo: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let type: String
    public let notNull: Bool
    public let isPK: Bool
    public let isFK: Bool

    public init(name: String, type: String, notNull: Bool, isPK: Bool, isFK: Bool) {
        self.name = name
        self.type = type
        self.notNull = notNull
        self.isPK = isPK
        self.isFK = isFK
    }
}

// MARK: - Formatting helpers

public enum Fmt {
    /// Compact row count, e.g. 18234 -> "18.2k", 52000 -> "52k".
    public static func rows(_ n: Int64) -> String {
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
