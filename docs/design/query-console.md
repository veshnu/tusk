# Query Console — Design Document

## Problem Statement

Tusk can browse schema and open tables, but there is no way to write and run
arbitrary SQL, and no way for Claude (over MCP) to author or run queries in the
app. We want a **query console**: a tab with a syntax‑highlighted, schema‑aware
SQL editor and a results grid, that both the human and Claude can drive — the
editor behaving like a file open in an editor that Claude can read and edit.

## Goals

- Right‑click a **database** or **table** in the explorer → **Query Console**.
  - From a DB: empty buffer. From a table: `SELECT * FROM <schema>.<table> LIMIT 100`.
- SQL editor with **syntax highlighting** and **schema‑aware autocomplete**
  (keywords/functions, table names, and `table.`→column completion).
- Editor buffer is **file‑backed** for state only — consoles restore on relaunch.
- **One connection per console**, bound to the console's database.
- MCP tools so Claude can: create a console for a DB, list open consoles, see
  which is selected, select one, get its SQL + results, **edit** its SQL (like
  editing an open file), and **run** it — with the run happening in the visible
  console and the results returned to Claude.
- JSONB / long‑text cells open a **value viewer** popup.

## Non-Goals

- Multi‑connection consoles (Tusk holds one open connection; a console binds to
  a database on that connection).
- A full code editor (multi‑cursor, find/replace beyond the system find bar,
  folding). Deferred.
- Live reflection of raw `.sql` file edits made outside the app (no file watcher);
  Claude edits via the MCP `set_query_console_sql` tool.
- Query cancellation mid‑run (a long query holds its lane until it returns).

## Background & Context

Tusk is a 100% native AppKit/SwiftUI app. The embedded terminal is SwiftTerm's
`LocalProcessTerminalView` (an `NSView`) wrapped in `NSViewRepresentable` — there
is **no WKWebView / JS bridge** anywhere. The `Database` actor already runs
per‑lane connections (a `browse` lane per DB, a `tabLane` per data tab), which is
exactly the "one connection per console" primitive. MCP was previously read‑only
and pull‑based (`AppTuskProvider` reads `AppModel` on the main actor); consoles
introduce the first **write** direction (MCP mutating live GUI state).

## Design Overview

```
  SchemaSidebar (right-click DB / Table)
        │  "Query Console"
        ▼
  AppModel.openConsole(database, seedSQL?)      ~/Library/Application Support/Tusk/
        │  QueryConsole {id, connId, db, sql}     consoles/
        │  write-through ─────────────────────►     <id>.sql     (buffer mirror)
        ▼                                            index.json   (open set + selected)
  WorkspaceTab { .data(DataTab) | .console(QueryConsole) }
        │
        ├── CenterPane renders the console:
        │     ┌─────────────────────────────────────────────┐
        │     │ SQLEditorView (NSTextView)  highlight + │
        │     │   completion popover (schema-aware)     [Run ⌘↵]
        │     ├── QueryStatusBar: conn · db · rows · ms · state ┤
        │     │ ResultGrid (shared)  → JSONB/long-text viewer   │
        │     └─────────────────────────────────────────────┘
        ▼
  Database.runConsole(id, db, sql, readOnly)  → dedicated PGConnection lane
        ▼
  PGConnection.query(sql, readOnly)  → PGRaw.exec (any SQL; rows or command)

  MCP (write path):  Claude ─JSON-RPC─► MCPSession ─► AppTuskProvider ─@MainActor─► AppModel
```

## Detailed Design

### Data Model

- `QueryConsole` (value type): `id` (UUID, also the `.sql` filename), `connectionId`,
  `database`, `title` (derived from SQL), `sql`, latest run (`columns`, `rows`,
  `running`, `error`, `elapsedMs`), `lastRunByClaude` (attribution), `readOnly`.
- `WorkspaceTab` enum: `.data(DataTab)` | `.console(QueryConsole)`. `AppModel.tabs`
  becomes `[WorkspaceTab]`; `DataTab` is unchanged. Illegal states (a console with
  a relation, a data tab with SQL) are unrepresentable.
- `SchemaIndex` (completion data): tables + columns keyed by bare and
  `schema.table` names, built from `AppModel.snapshots` and a column cache.

### File Layout

Runtime (state only — `ConsoleStore`):
```
~/Library/Application Support/Tusk/consoles/
├── index.json          # { selected, consoles:[{id, connectionId, database, title, readOnly}] }
└── <console-id>.sql    # the buffer mirror, one per console
```
Source:
```
Sources/Tusk/QueryConsole.swift      QueryConsole, WorkspaceTab, ConsoleStore
Sources/Tusk/SQLEditorView.swift     NSViewRepresentable NSTextView + highlighter
Sources/Tusk/SQLCompletion.swift     completion engine + DS completion popover
Sources/Tusk/QueryConsoleView.swift  ConsolePane, ResultGrid, CellValueViewer
Sources/Tusk/AppModel.swift          tabs:[WorkspaceTab], console lifecycle, persistence
Sources/Tusk/Workspace.swift         right-click menus; CenterPane console rendering
Sources/Tusk/AppTuskProvider.swift   console MCP methods (@MainActor writes)
Sources/TuskCore/PostgresService.swift  query()/runConsole() + console lane
Sources/TuskCore/MCPProvider.swift   ConsoleInfo/ConsoleDetail + protocol (default throws)
Sources/TuskCore/MCPSession.swift    7 console tools + schemas; TuskPaths.consolesDir
```

### Editor (native)

`SQLEditorView` wraps an `NSTextView` subclass. The buffer is a plain `String`
binding routed through `AppModel.setConsoleSQL` (write‑through to disk, debounced).
Syntax highlighting tokenizes on each edit and paints `NSTextStorage` with the DS
"Xcode Default" syntax colors (light/dark). Completion is a custom borderless
`NSPanel` hosting the DS `SqlCompletions` card (kind glyphs, active‑row accent bar,
matched‑prefix emphasis, pg‑type detail, footer hints); it is dot‑triggered and
context‑aware (`ident.` → that table's columns, resolving `FROM/JOIN … alias`;
otherwise keywords + functions + tables). Arrow/⏎/tab/esc are routed to the popover;
**⌘↵ runs**.

### Editing model (the shared surface)

In‑memory `QueryConsole.sql` is the source of truth. Human keystrokes and MCP
`set_query_console_sql` both replace it through one path; the `.sql` file is a
durable mirror. `set_query_console_sql` replaces the buffer (VSCode "external edit"
semantics, last‑writer‑wins, caret preserved best‑effort). Restore on connect
reads back consoles saved for that connection.

### Execution

`Database.runConsole(id, database, sql, readOnly)` runs on a dedicated
`PGConnection` lane keyed by console id (= one connection per console).
`readOnly` issues `SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY`. Runs
triggered by Claude set `lastRunByClaude` and render in the visible tab.

### MCP tools

```
create_query_console(database_id, sql?)   → { console_id }        opens + focuses a tab
list_query_consoles()                     → [{ id, database, title, selected }]
get_selected_query_console()              → { console_id | null }
select_query_console(console_id)          → focuses the tab
get_query_console(console_id)             → { sql, columns, rows, error, running, … }
set_query_console_sql(console_id, sql)    → replaces buffer (mirrors to file)
run_query_console(console_id)             → runs current SQL, returns results (rows capped 200)
```
Console tools live behind default protocol methods that throw for the headless
CLI (`EnvTuskProvider`) — they require the running app. Non‑active connections
return the existing "Open this connection in Tusk" error.

## Tradeoffs & Alternatives Considered

| Decision | Alternatives | Choice & why |
|---|---|---|
| Editor | Native NSTextView · CodeMirror in WKWebView · SwiftPM pkg | **NSTextView** — matches the all‑native app; buffer is an owned `String` (clean file‑backing + MCP set, no bridge races). |
| Completion | Custom popover · Apple stock panel · CodeMirror lang‑sql | **Custom popover** — schema‑aware `table.` completion that matches the DS. |
| Tab model | enum · struct+kind+optionals · protocol | **enum** — illegal states unrepresentable; `DataTab` untouched. |
| Sync model | in‑mem source of truth + file mirror · file‑watched | **in‑mem + mirror** — one write path into the live buffer; no watcher race. |
| Execution | Claude can run (visible) · edit‑only | **Claude can run in‑view, attributed** — closes the agentic loop; visibility is the safety model. |

## Failure Modes

| Codepath | Scenario | Test? | Handled? | Silent? |
|---|---|---|---|---|
| run_query_console | invalid SQL | ✗ | ✓ → `console.error`, rendered; MCP `isError` | ✗ |
| create_query_console | non‑active connection | ✗ | ✓ → `requireActive` error | ✗ |
| set_sql mid‑type | buffer replaced | ✗ | ✓ (last‑writer‑wins, visible) | ✗ |
| write‑through | disk/permission failure | ✗ | ✓ → `NSLog`, in‑mem keeps working (best‑effort) | ⚠ (by design) |
| restore | corrupt `.sql`/index | ✗ | ✓ → skip/empty | ✗ |
| run | connection dropped | ✗ | ✓ → exec throws → `console.error` | ✗ |
| close console | run in‑flight | ✗ | ✓ → `updateConsole` existence guard; lane released | ✗ |
| long query | no cancel (v1) | ✗ | ⚠ known limitation; state shows "running" | ✗ |
| get/select/set | unknown console_id | ✗ | ✓ → `notFound` | ✗ |

No 🔴 (test✗ + unhandled + silent) rows. Write‑through failure is deliberately
best‑effort (mirrors the existing MCP‑socket‑start posture).

## Open Questions

- [ ] Prefetch of columns for completion is capped at 150 tables per database and
      runs on the browse lane — revisit for very large schemas.
- [ ] Doc side‑panel in the completion popup (DS shows one) not yet built.
- [ ] Editor lacks find/replace beyond the system find bar; no query history.

## Implementation Plan

1. TuskCore: `PGConnection.query`, `Database.runConsole`/`closeConsole`,
   `ConsoleInfo`/`ConsoleDetail`, protocol + default throws, `TuskPaths.consolesDir`. ✔
2. Model: `QueryConsole` / `WorkspaceTab` / `ConsoleStore`. ✔
3. Editor + completion (`SQLEditorView`, `SQLCompletion`). ✔
4. `AppModel` tab generalization + console lifecycle + persistence + restore. ✔
5. UI: right‑click menus, `ConsolePane`, shared `ResultGrid`, `CellValueViewer`. ✔
6. MCP: `AppTuskProvider` console methods + `MCPSession` tools/schemas. ✔
7. Build clean. ✔ · **Pending: runtime verification by running the app** (GUI can't
   be driven headlessly here) — open Tusk, connect, right‑click a table → Query
   Console, type/run, and exercise the MCP tools from Claude Code.

## References

- Tusk Design System (`~/Downloads/Tusk Design System`): `components/editor/`
  (`SqlEditor`, `SqlCompletions`, `QueryStatusBar`), `components/data/DataGrid`,
  `tokens/semantic.css` (syntax colors), `tokens/shadows.css`.
