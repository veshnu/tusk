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
| **MCP server (`tusk mcp`)** | 🚧 Next up |
| Read query execution + result grid | 🚧 Planned |
| Guarded writes / migrations with human approval | 🗺️ Roadmap |
| MySQL, SQLite, and other engines | 🗺️ Roadmap |

Today it's the **best-in-class Postgres explorer** half. The MCP half is the reason the
project exists and is the immediate focus — see the [Roadmap](#roadmap).

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

## The MCP vision

Once `tusk mcp` lands, adding Tusk to Claude Code will be a one-liner:

```jsonc
// ~/.claude/mcp.json (illustrative — API not final)
{
  "mcpServers": {
    "tusk": {
      "command": "tusk",
      "args": ["mcp", "--connection", "llamacloud"]
    }
  }
}
```

Planned tools the server will expose to the agent:

| Tool | Purpose |
| --- | --- |
| `list_databases` | Every database on the connected server |
| `describe_schema` | Tables, columns, types, keys, indexes for a database |
| `run_query` | Execute a **read-only** SQL query, returns rows as structured JSON |
| `explain_query` | `EXPLAIN`/`EXPLAIN ANALYZE` a query without running it destructively |
| `propose_write` | Draft an `INSERT`/`UPDATE`/migration that a human approves in the GUI |

Design principles:

- **Read by default, write by consent.** Mutations are surfaced in the GUI for explicit
  human approval before they ever touch the database.
- **Least privilege.** Point the MCP server at a read-only role and it physically cannot do
  more than read.
- **Shared context.** The agent sees exactly what you see in the explorer, so its SQL is
  grounded in your real schema — not a hallucinated one.

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
│   └── PostgresService.swift #   Database actor — one libpq connection per database
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
- **`AppModel`** is the single source of truth the SwiftUI views observe. The MCP tools and
  the GUI will read the same model, which is what makes the two halves stay in sync.

> The GUI build product is `Tusk` and the CLI build product is `tuskcli` (installed as
> `tusk`) — named apart on purpose, since macOS's case-insensitive filesystem can't hold
> both `Tusk` and `tusk` binaries in the same build directory.

---

## Roadmap

- [ ] **`tusk mcp`** — stdio MCP server exposing schema introspection + read queries
- [ ] Read query execution with a result grid in the GUI
- [ ] Human-in-the-loop write/migration approval flow
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
