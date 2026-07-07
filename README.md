<div align="center">

# 🐘 Tusk

**A slick, open-source, AI-first database tool — with a built-in MCP server.**

Browse your database like a native app. Query it in plain English through Claude Code
using the subscription you already pay for. No extra API keys, no per-token billing.

</div>

---

## Why Tusk

Every database GUI is a read-only museum: you click through tables, you copy-paste SQL,
you alt-tab to an AI in the browser and paste your schema in by hand. Meanwhile every
serious engineer now has an AI coding agent one keystroke away.

Tusk closes that gap. It is **two things in one binary**:

1. **A fast, beautiful desktop client** for exploring and understanding your database.
2. **An MCP (Model Context Protocol) server** that exposes that same database — safely and
   with your GUI context — to any MCP client: **Claude Code, Claude Desktop, Cursor**, and
   anything else that speaks MCP.

Because it rides on MCP, you drive Tusk with your **existing Claude subscription**.
Ask *"which orders are missing a shipping address?"* in Claude Code and it introspects the
schema, writes the SQL, runs it through Tusk, and hands you the answer — while you watch
the same query land in the GUI.

> **AI-first, not AI-bolted-on.** The introspection layer, the query engine, and the safety
> rails are built to be consumed by an agent first and a human second.

---

## Status

Tusk is early and moving fast. Here's the honest picture:

| Area | State |
| --- | --- |
| Native macOS client (SwiftUI/AppKit) | ✅ Working |
| Live schema explorer: server → database → schema → table | ✅ Working |
| Multi-database browsing per server (lazy-loaded) | ✅ Working |
| Column detail with PK / FK / NOT NULL flags | ✅ Working |
| Connection manager, light/dark themes | ✅ Working |
| Direct `libpq` connection (no ORM, no server) | ✅ Working |
| **MCP server** (`list_connections`, `list_databases`, `list_tables`, `describe_table`) | ✅ Working (v0) |
| Served over a dedicated unix socket; `tusk mcp` bridges Claude Code's stdio to it | ✅ Working |
| Read-only `run_query` tool | 🚧 Planned |
| Guarded writes / migrations with human approval | 🗺️ Roadmap |
| MySQL, SQLite, and other engines | 🗺️ Roadmap |

The Postgres explorer and a **metadata MCP server** both work today. A read-only query tool
and writes-by-approval are next — see the [Roadmap](#roadmap).

---

## What's here today

- **Server → database → schema → relation tree.** A connection is a *server*, not a single
  database. Tusk enumerates every database you can reach and loads each one's schema lazily
  when you expand it.
- **Real `libpq`, no middleman.** Connects straight to Postgres via the C client library.
  No bundled proxy, no telemetry, nothing between you and your data.
- **Column introspection** with primary-key, foreign-key, and NOT NULL flags, pulled live
  from `pg_catalog`.
- **Saved connections** with per-connection SSL mode and environment tags; passwords go to
  the macOS Keychain, never to disk in plaintext.
- **Headless self-check** (`tusk selfcheck`) that exercises the entire connect → snapshot
  → columns path against a live database — handy for CI and for verifying an environment.

---

## MCP: drive your database from Claude Code

### How it connects (no ports)

When you open a connection in the Tusk app, it hosts an MCP server on a **dedicated unix
socket** — Tusk's equivalent of `/var/run/docker.sock`:

```
~/Library/Application Support/Tusk/mcp.sock
```

`tusk mcp` is a tiny bridge Claude Code spawns over **stdio**; it relays that stdio to the
socket. So there's **no TCP port** to collide with anything, and the agent talks to the same
live connection you have open in the GUI.

```
Claude Code ──stdio──▶ tusk mcp ──unix socket──▶ Tusk.app ──▶ Postgres
```

### Add it to Claude Code

```bash
claude mcp add tusk -- tusk mcp
```

Then, in the app, connect to a database — and ask Claude Code things like
*"what columns does public.orders have?"* or *"count rows per status in orders"*.

If the app isn't running, `tusk mcp` falls back to serving directly over stdio using
standard `PG*` environment variables, so it still works headless (e.g. in CI):

```bash
claude mcp add tusk --env PGHOST=localhost --env PGPORT=5432 \
  --env PGDATABASE=app_dev --env PGUSER=postgres --env PGPASSWORD=secret -- tusk mcp
```

### Tools exposed today

The tools are a navigable view of Tusk's own state — connection → database → table → columns.
IDs flow from one call into the next (`connection_id` → `database_id` → `table_id`).

| Tool | Purpose |
| --- | --- |
| `list_connections` | All connections configured in Tusk, each with its status (`connected`/`disconnected`) |
| `list_databases(connection_id)` | Databases Tusk knows for a connection — its cached/configured state, **no fresh server round-trip** |
| `list_tables(database_id)` | All tables and views in a database |
| `describe_table(database_id, table_id)` | A table's columns, types, and PK/FK/NOT NULL flags |

**Metadata only — no data, no SQL.** The server exposes schema and connection *structure*, not
row data, and there is no arbitrary-query tool. So it can't return table contents, and it
can't reach Postgres's credential catalogs. Plaintext passwords are never stored in Postgres,
and no tool ever emits Tusk's own saved connection password. The security boundary for
whatever *is* exposed is to connect Tusk as a **least-privilege, read-only role**.

Tusk opens one connection at a time, so `list_tables`/`describe_table` apply to the
**connected** connection; others list via `list_connections` but must be opened in the app
before you can drill into them.

### Where it's heading

- **A query tool, by consent** — a future `run_query` (read-only) and `propose_write` (writes
  a human approves in the GUI) — deliberately *not* in this first cut.
- **Shared context** — because the server rides on the app's live connections, what the agent
  sees is exactly what's open in the GUI.

---

## Getting started

### Requirements

- **macOS 13** (Ventura) or newer
- **Swift 5.9+** toolchain (ships with recent Xcode / Command Line Tools)
- **libpq** — the PostgreSQL client library

Install `libpq` via Homebrew:

```bash
brew install libpq
```

### Install (both the app and the CLI)

Tusk ships as two pieces from one repo: the **GUI app** (`Tusk.app`) and a tiny
**`tusk` CLI** that Claude Code spawns for MCP. Both install together.

Once there's a signed release, the one-liner will be a Homebrew **cask** (a single cask
installs the app *and* puts `tusk` on `PATH`):

```bash
brew tap veshnu/tusk
brew install --cask tusk     # installs Tusk.app + the `tusk` CLI
```

To build and install from source today:

```bash
git clone <this-repo> tusk
cd tusk
brew install libpq
make install                 # → /Applications/Tusk.app  +  tusk on PATH
```

Other Makefile targets: `make` (build + assemble `dist/Tusk.app` and `dist/tusk` without
installing), `make dist` (zip a release artifact), `make uninstall`, `make clean`.

For a plain dev run without installing: `swift run Tusk` launches the app,
`swift run tuskcli <command>` runs the CLI.

### The `tusk` CLI

```
tusk mcp         start the MCP server over stdio (for Claude Code & other MCP clients)
tusk selfcheck   verify the libpq path against a live Postgres (reads PG* env vars)
tusk doctor      check the local environment (libpq, app install)
tusk version
```

### Verify a connection headlessly

`tusk selfcheck` connects, enumerates databases, and snapshots the schema — all without
opening a window. It reads standard `PG*` environment variables:

```bash
PGHOST=localhost PGPORT=5432 PGDATABASE=app_dev \
PGUSER=postgres PGPASSWORD=secret \
tusk selfcheck
```

A healthy run ends with `SELFCHECK_OK`.

> **Note on Homebrew paths.** `Package.swift` expects Apple-Silicon Homebrew
> (`/opt/homebrew/opt/libpq`). On Intel Macs, adjust the `libpqInclude` / `libpqLib`
> constants at the top of `Package.swift` to your `brew --prefix libpq` location.

---

## Architecture

```
Sources/
├── CPostgres/                # system-library shim exposing libpq to Swift
├── TuskCore/                 # shared, GUI-free core (linked by both app and CLI)
│   ├── Models.swift          #   Connection, Relation, ColumnInfo, DBObjectKind
│   ├── PostgresService.swift #   Database actor — one libpq connection per database
│   ├── MCPSession.swift      #   MCP JSON-RPC session + tool definitions
│   ├── MCPProvider.swift     #   TuskStateProviding protocol + DTOs + headless provider
│   └── MCPTransport.swift    #   unix-socket server, stdio session, stdio↔socket bridge
├── Tusk/                     # GUI app (SwiftUI/AppKit) → Tusk.app
│   ├── TuskApp.swift         #   @main app entry, window + routing
│   ├── AppModel.swift        #   observable app state (connections, schema, selection)
│   ├── AppTuskProvider.swift #   MCP provider backed by live app state
│   ├── Persistence.swift     #   saved connections + Keychain
│   ├── ConnectScreen.swift   #   connection picker
│   ├── Workspace.swift       #   explorer tree, table detail, info rail
│   ├── NewConnectionModal.swift
│   ├── Components.swift      #   buttons, fields, badges
│   └── Theme.swift           #   palette, light/dark
└── tuskcli/                  # tiny CLI → installed as `tusk` (mcp / selfcheck / doctor)
    └── main.swift
```

- **`TuskCore` is GUI-free**, so the `tusk` CLI links it without dragging in
  SwiftUI/AppKit — the CLI stays small and fast to spawn (which matters for `tusk mcp`).
- **`Database` is a Swift `actor`** that owns the `libpq` handles. Because a Postgres
  connection is bound to a single database, Tusk keeps **one connection per database**,
  cloned from the base config, and opens them on demand. This is exactly the boundary the
  MCP server will sit behind.
- **`AppModel`** is the single source of truth the SwiftUI views observe, and it starts an
  `MCPSocketServer` on the same `Database` when a connection opens — so the MCP tools and the
  GUI read the exact same live connections.

> The GUI build product is `Tusk` and the CLI build product is `tuskcli` (installed as
> `tusk`) — named apart on purpose, since macOS's case-insensitive filesystem can't hold
> both `Tusk` and `tusk` binaries in the same build directory.

---

## Roadmap

- [x] **MCP server** over a unix socket: `list_connections`, `list_databases`, `list_tables`,
      `describe_table`; `tusk mcp` bridges Claude Code's stdio to it
- [ ] Read-only `run_query` tool (+ a result grid in the GUI)
- [ ] Human-in-the-loop write/migration approval flow (`propose_write`)
- [ ] Connection pooling / eviction for many-database servers
- [ ] Query history and saved queries, shared between agent and human
- [ ] Additional engines: MySQL, SQLite
- [ ] Linux build

---

## Contributing

This is an open-source project and contributions are very welcome — especially on the MCP
server, the query engine, and additional database engines. Open an issue to discuss a
direction before large changes. Run `swift run Tusk --selfcheck` against a local Postgres
before sending a PR that touches the data layer.

---

## License

MIT. See [`LICENSE`](LICENSE).
