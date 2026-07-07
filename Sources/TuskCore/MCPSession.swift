import Foundation

// MARK: - Well-known paths

public enum TuskPaths {
    /// ~/Library/Application Support/Tusk
    public static var appSupportDir: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Tusk", isDirectory: true).path
    }

    /// The dedicated unix-domain socket the app serves MCP on — Tusk's equivalent
    /// of `/var/run/docker.sock`. `tusk mcp` connects here and relays to Claude Code.
    public static var mcpSocketPath: String {
        appSupportDir + "/mcp.sock"
    }
}

// MARK: - Errors

enum MCPError: LocalizedError {
    case invalidArguments(String)
    case unknownTool(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let m): return m
        case .unknownTool(let name): return "Unknown tool: \(name)"
        }
    }
}

// MARK: - JSON-RPC helpers (line-delimited JSON, the MCP stdio framing)

private func encodeLine(_ obj: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: []) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}

private func successResponse(id: Any?, result: [String: Any]) -> String {
    encodeLine(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
}

private func errorResponse(id: Any?, code: Int, message: String) -> String {
    encodeLine(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])
}

private func jsonText(_ obj: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}

// MARK: - MCP session

/// One MCP conversation over line-delimited JSON-RPC 2.0. Transport-agnostic:
/// feed it a request line, it returns the response line (or nil for notifications).
/// Backed by a shared `Database` actor, so every session sees the same live connections.
public actor MCPSession {
    private let db: Database
    private let base: Connection

    public init(db: Database, base: Connection) {
        self.db = db
        self.base = base
    }

    public static let serverName = "tusk"
    public static let serverVersion = "0.1.0"

    public func handle(_ line: String) async -> String? {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return errorResponse(id: nil, code: -32700, message: "Parse error")
        }
        let id = obj["id"]
        let method = obj["method"] as? String ?? ""
        let params = obj["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let protocolVersion = (params["protocolVersion"] as? String) ?? "2024-11-05"
            return successResponse(id: id, result: [
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": Self.serverName, "version": Self.serverVersion],
            ])
        case "notifications/initialized", "notifications/cancelled":
            return nil // notifications get no response
        case "ping":
            return successResponse(id: id, result: [:])
        case "tools/list":
            return successResponse(id: id, result: ["tools": Self.toolDefinitions])
        case "tools/call":
            return await callTool(id: id, params: params)
        default:
            if id == nil { return nil }
            return errorResponse(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func callTool(id: Any?, params: [String: Any]) async -> String? {
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        do {
            let text = try await runTool(name: name, args: args)
            return successResponse(id: id, result: ["content": [["type": "text", "text": text]], "isError": false])
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return successResponse(id: id, result: ["content": [["type": "text", "text": "Error: \(msg)"]], "isError": true])
        }
    }

    private func runTool(name: String, args: [String: Any]) async throws -> String {
        // Default the target database to the connection's own database.
        let database = (args["database"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? base.database

        switch name {
        case "list_databases":
            let dbs = try await db.databases()
            return jsonText(["databases": dbs])

        case "describe_schema":
            let snap = try await db.snapshot(database: database)
            let rels = snap.relations.map {
                ["schema": $0.schema, "name": $0.name, "kind": $0.kind.rawValue, "estimatedRows": $0.estRows] as [String: Any]
            }
            return jsonText(["database": database, "relations": rels])

        case "describe_table":
            guard let schema = (args["schema"] as? String), !schema.isEmpty,
                  let table = (args["table"] as? String), !table.isEmpty else {
                throw MCPError.invalidArguments("`schema` and `table` are required")
            }
            let cols = try await db.columns(database: database, schema: schema, table: table)
            let out = cols.map {
                ["name": $0.name, "type": $0.type, "notNull": $0.notNull, "primaryKey": $0.isPK, "foreignKey": $0.isFK] as [String: Any]
            }
            return jsonText(["database": database, "schema": schema, "table": table, "columns": out])

        case "run_query":
            guard let sql = (args["sql"] as? String), !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MCPError.invalidArguments("`sql` is required")
            }
            let qr = try await db.query(database: database, sql: sql)
            var payload: [String: Any] = [
                "database": database,
                "columns": qr.columns,
                "rowCount": qr.rows.count,
                "rows": qr.rows.map { row in row.map { cell in cell.map { $0 as Any } ?? NSNull() } },
            ]
            if qr.truncated { payload["truncated"] = true }
            return jsonText(payload)

        default:
            throw MCPError.unknownTool(name)
        }
    }

    // MARK: Tool schemas advertised to the client

    static let toolDefinitions: [[String: Any]] = [
        [
            "name": "list_databases",
            "description": "List all databases on the connected Postgres server.",
            "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
        ],
        [
            "name": "describe_schema",
            "description": "List tables, views, and other relations in a database (defaults to the connected database).",
            "inputSchema": [
                "type": "object",
                "properties": ["database": ["type": "string", "description": "Database name; defaults to the connected database."]],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "describe_table",
            "description": "Describe a table's columns, including types and primary/foreign-key/NOT NULL flags.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "database": ["type": "string", "description": "Database name; defaults to the connected database."],
                    "schema": ["type": "string", "description": "Schema name, e.g. public."],
                    "table": ["type": "string", "description": "Table name."],
                ],
                "required": ["schema", "table"],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "run_query",
            "description": "Run a READ-ONLY SQL query and return the rows. Executes inside a read-only transaction — any write is rejected by Postgres. Results are capped at 1000 rows.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "database": ["type": "string", "description": "Database name; defaults to the connected database."],
                    "sql": ["type": "string", "description": "A read-only SQL statement (SELECT/EXPLAIN/…)."],
                ],
                "required": ["sql"],
                "additionalProperties": false,
            ],
        ],
    ]
}
