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

public enum MCPError: LocalizedError {
    case invalidArguments(String)
    case unknownTool(String)
    case notFound(String)
    case notConnected(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArguments(let m): return m
        case .unknownTool(let name): return "Unknown tool: \(name)"
        case .notFound(let m): return "Not found: \(m)"
        case .notConnected(let m): return m
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
    private let provider: TuskStateProviding

    public init(provider: TuskStateProviding) {
        self.provider = provider
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
        func requiredString(_ key: String) throws -> String {
            guard let v = (args[key] as? String), !v.isEmpty else {
                throw MCPError.invalidArguments("`\(key)` is required")
            }
            return v
        }

        switch name {
        case "list_connections":
            let conns = await provider.listConnections()
            let out = conns.map {
                ["id": $0.id, "name": $0.name, "host": $0.host, "port": $0.port,
                 "user": $0.user, "database": $0.database, "env": $0.env, "status": $0.status] as [String: Any]
            }
            return jsonText(["connections": out])

        case "list_databases":
            let connectionId = try requiredString("connection_id")
            let dbs = try await provider.listDatabases(connectionId: connectionId)
            let out = dbs.map { ["id": $0.id, "name": $0.name, "connectionId": $0.connectionId] as [String: Any] }
            return jsonText(["databases": out])

        case "list_tables":
            let databaseId = try requiredString("database_id")
            let tables = try await provider.listTables(databaseId: databaseId)
            let out = tables.map { ["id": $0.id, "name": $0.name, "schema": $0.schema, "kind": $0.kind] as [String: Any] }
            return jsonText(["tables": out])

        case "describe_table":
            let databaseId = try requiredString("database_id")
            let tableId = try requiredString("table_id")
            let cols = try await provider.describeTable(databaseId: databaseId, tableId: tableId)
            let out = cols.map {
                ["name": $0.name, "type": $0.type, "notNull": $0.notNull, "primaryKey": $0.isPK, "foreignKey": $0.isFK] as [String: Any]
            }
            return jsonText(["databaseId": databaseId, "tableId": tableId, "columns": out])

        default:
            throw MCPError.unknownTool(name)
        }
    }

    // MARK: Tool schemas advertised to the client

    static let toolDefinitions: [[String: Any]] = [
        [
            "name": "list_connections",
            "description": "List all Postgres connections configured in Tusk, with their connection status.",
            "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
        ],
        [
            "name": "list_databases",
            "description": "List the databases Tusk knows for a connection. Returns Tusk's configured/known state; does not issue a fresh query to the server.",
            "inputSchema": [
                "type": "object",
                "properties": ["connection_id": ["type": "string", "description": "A connection id from list_connections."]],
                "required": ["connection_id"],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "list_tables",
            "description": "List all tables and views in a database.",
            "inputSchema": [
                "type": "object",
                "properties": ["database_id": ["type": "string", "description": "A database id from list_databases."]],
                "required": ["database_id"],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "describe_table",
            "description": "Describe a table's columns, including types and primary/foreign-key/NOT NULL flags.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "database_id": ["type": "string", "description": "A database id from list_databases."],
                    "table_id": ["type": "string", "description": "A table id from list_tables (\"schema.table\")."],
                ],
                "required": ["database_id", "table_id"],
                "additionalProperties": false,
            ],
        ],
    ]
}
