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
| **MCP server** (`list_databases`, `describe_schema`, `describe_table`, read-only `run_query`) | ✅ Working (v0) |
| Served over a dedicated unix socket; `tusk mcp` bridges Claude Code's stdio to it | ✅ Working |
| In-GUI result grid for `run_query` | 🚧 Planned |
| Guarded writes / migrations with human approval | 🗺️ Roadmap |
| MySQL, SQLite, and other engines | 🗺️ Roadmap |

The Postgres explorer and a **read-only MCP server** both work today. Writes-by-approval and
a result grid are next — see the [Roadmap](#roadmap).

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

| Tool | Purpose |
| --- | --- |
| `list_databases` | Every database on the connected server |
| `describe_schema` | Tables/views/relations in a database (defaults to the connected one) |
| `describe_table` | A table's columns, types, and PK/FK/NOT NULL flags |
| `run_query` | Execute a **read-only** SQL query; returns rows as structured JSON |

**`run_query` is safe by construction:** every statement runs inside a `READ ONLY`
transaction with a statement timeout, so a write is rejected by Postgres itself
(*"cannot execute INSERT in a read-only transaction"*) — no fragile SQL parsing — and the
transaction is always rolled back. Results are capped at 1000 rows.

**No credentials leak through the tools.** Plaintext passwords are never stored in Postgres,
and no tool ever emits Tusk's own saved connection password. As defense-in-depth, `run_query`
also blocks the credential catalogs that hold password *hashes* (`pg_authid`, `pg_shadow`,
`rolpassword`) even on a superuser connection. The real security boundary is still to connect
Tusk as a **least-privilege, read-only role**.

### Where it's heading

- **Write by consent** — `propose_write` drafts an `INSERT`/`UPDATE`/migration that a human
  approves in the GUI before it touches the database.
- **Least privilege** — point the connection at a read-only role and it physically cannot do
  more than read.
- **Shared context** — because the server rides on the app's live connection, the agent's SQL
  is grounded in your real schema, not a hallucinated one.

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
│   └── MCPTransport.swift    #   unix-socket server, stdio session, stdio↔socket bridge
├── Tusk/                     # GUI app (SwiftUI/AppKit) → Tusk.app
│   ├── TuskApp.swift         #   @main app entry, window + routing
│   ├── AppModel.swift        #   observable app state (connections, schema, selection)
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

- [x] **MCP server** over a unix socket: `list_databases`, `describe_schema`,
      `describe_table`, read-only `run_query`; `tusk mcp` bridges Claude Code's stdio to it
- [ ] Result grid in the GUI for `run_query`
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
