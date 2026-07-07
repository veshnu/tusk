import SwiftUI
import AppKit
import TuskCore

struct Workspace: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.palette) var pal

    @AppStorage("tusk.railWidth") private var railWidth: Double = 250

    var body: some View {
        VStack(spacing: 0) {
            TitleBar()
            HStack(spacing: 0) {
                SchemaSidebar()
                CenterPane()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                ResizeHandle(width: $railWidth, range: 200...520)
                InfoRail(width: CGFloat(railWidth))
            }
        }
        .background(pal.surfaceApp)
        .ignoresSafeArea(.container, edges: .top)
    }
}

// MARK: - Draggable resize handle (grows the pane to its right)

private struct ResizeHandle: View {
    @Environment(\.palette) var pal
    @Binding var width: Double
    let range: ClosedRange<Double>

    @State private var dragStartWidth: Double?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 7)
            .overlay(
                Rectangle()
                    .fill(hovering ? pal.accent : pal.borderDefault)
                    .frame(width: hovering ? 2 : 1)
            )
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = dragStartWidth ?? width
                        if dragStartWidth == nil { dragStartWidth = base }
                        // Handle sits on the pane's left edge: dragging left widens it.
                        let proposed = base - Double(value.translation.width)
                        width = min(max(proposed, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
    }
}

// MARK: - Title bar (real macOS window; leaves room for traffic lights)

private struct TitleBar: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.palette) var pal

    var body: some View {
        HStack(spacing: 12) {
            // Reserve space for the real macOS traffic lights (hiddenTitleBar).
            Spacer().frame(width: 62)

            HStack(spacing: 7) {
                Image(systemName: "hexagon.fill")
                    .font(.system(size: 13))
                    .foregroundColor(pal.accent)
                Text("Tusk")
                    .font(.ui(13, weight: .semibold))
                    .foregroundColor(pal.textPrimary)
            }

            Spacer()

            // Connection switcher / disconnect
            Menu {
                Button {
                    model.refreshSchema()
                } label: { Label("Refresh schema", systemImage: "arrow.clockwise") }
                Divider()
                Button(role: .destructive) {
                    model.disconnect()
                } label: { Label("Disconnect", systemImage: "bolt.horizontal.circle") }
            } label: {
                HStack(spacing: 8) {
                    StatusDot(status: "connected", size: 7)
                    Text(model.activeConn?.name ?? "—")
                        .font(.ui(12))
                        .foregroundColor(pal.textSecondary)
                    Text(model.selectedDatabase ?? model.activeConn?.database ?? "")
                        .font(.mono(11))
                        .foregroundColor(pal.textFaint)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(pal.textFaint)
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.radiusSM, style: .continuous)
                        .fill(pal.surfaceCard)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.radiusSM, style: .continuous)
                        .strokeBorder(pal.borderDefault, lineWidth: 1)
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Button {
                model.toggleTheme()
            } label: {
                Image(systemName: model.isDark ? "sun.max" : "moon")
                    .font(.system(size: 13))
                    .foregroundColor(pal.textMuted)
                    .frame(width: 28, height: 26)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(pal.surfacePanel)
        .overlay(Divider().overlay(pal.borderDefault), alignment: .bottom)
    }
}

// MARK: - Schema sidebar (live object tree)

private struct SchemaSidebar: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.palette) var pal

    @State private var filter = ""
    @State private var collapsedSchemas: Set<String> = []   // keyed "database.schema"
    @State private var serverCollapsed = false

    /// Schemas (and their relations) for one database, filtered by the search box.
    private func groups(for database: String) -> [(schema: String, relations: [Relation])] {
        guard let relations = model.snapshots[database]?.relations else { return [] }
        var order: [String] = []
        var map: [String: [Relation]] = [:]
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        for r in relations {
            if !q.isEmpty && !r.name.lowercased().contains(q) && !r.schema.lowercased().contains(q) { continue }
            if map[r.schema] == nil { order.append(r.schema); map[r.schema] = [] }
            map[r.schema]?.append(r)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    private var tableCount: Int {
        model.selectedSnapshot?.relations.filter { $0.kind == .table || $0.kind == .partitioned }.count ?? 0
    }

    var body: some View {
        VStack(spacing: 0) {
            // Filter
            HStack {
                TuskTextField(placeholder: "Filter objects…", text: $filter, leadingIcon: "magnifyingglass", mono: false)
            }
            .padding(.horizontal, 10)
            .frame(height: Metrics.toolbarHeight)
            .overlay(Divider().overlay(pal.borderSubtle), alignment: .bottom)

            // Tree
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text("EXPLORER")
                        .font(.ui(10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundColor(pal.textFaint)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 4)

                    if model.loadingSchema {
                        loadingRow
                    } else if let err = model.schemaError {
                        errorRow(err)
                    } else {
                        // Server node (user@host)
                        TreeRow(depth: 0, icon: "server.rack", label: model.serverLabel,
                                trailing: nil, selected: model.inspector == .server,
                                expandable: true, expanded: !serverCollapsed,
                                onToggle: { serverCollapsed.toggle() },
                                onSelect: { model.selectServer() },
                                onOpen: { serverCollapsed.toggle() })

                        if !serverCollapsed {
                            ForEach(model.databases, id: \.self) { dbName in
                                databaseNode(dbName)
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
            }

            // Footer
            HStack(spacing: 7) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 11))
                    .foregroundColor(pal.textFaint)
                Text(model.selectedDatabase ?? "—")
                    .font(.mono(11))
                    .foregroundColor(pal.textMuted)
                Text("·").foregroundColor(pal.textFaint)
                Text("\(tableCount) tables")
                    .font(.mono(11))
                    .foregroundColor(pal.textMuted)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .overlay(Divider().overlay(pal.borderSubtle), alignment: .top)
        }
        .frame(width: 248)
        .background(pal.surfacePanel)
        .overlay(Divider().overlay(pal.borderDefault), alignment: .trailing)
    }

    /// One database node plus its (lazily-loaded) schemas and relations.
    @ViewBuilder private func databaseNode(_ dbName: String) -> some View {
        let dbExpanded = model.expandedDatabases.contains(dbName)
        let isActive = dbName == model.activeConn?.database

        TreeRow(depth: 1, icon: "cylinder.split.1x2", label: dbName,
                trailing: nil, selected: model.inspector == .database(dbName),
                expandable: true, expanded: dbExpanded, muted: !isActive,
                onToggle: { model.toggleDatabase(dbName) },
                onSelect: { model.selectDatabase(dbName) },
                onOpen: { model.toggleDatabase(dbName) })

        if dbExpanded {
            if model.loadingDatabases.contains(dbName) {
                inlineRow(depth: 2) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text("Loading…").font(.ui(12)).foregroundColor(pal.textMuted)
                }
            } else if let err = model.databaseErrors[dbName] {
                inlineRow(depth: 2) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundColor(pal.danger)
                    Text(err).font(.mono(11)).foregroundColor(pal.danger).lineLimit(2)
                }
            } else {
                let schemaGroups = groups(for: dbName)
                ForEach(schemaGroups, id: \.schema) { group in
                    let key = "\(dbName).\(group.schema)"
                    let expanded = !collapsedSchemas.contains(key)
                    TreeRow(depth: 2, icon: "shippingbox", label: group.schema,
                            trailing: "\(group.relations.count)", selected: false,
                            expandable: true, expanded: expanded,
                            onToggle: { toggleSchema(key) },
                            onSelect: { model.selectDatabase(dbName) },
                            onOpen: { toggleSchema(key) })

                    if expanded {
                        ForEach(group.relations) { rel in
                            TreeRow(depth: 3, icon: rel.kind.iconName, label: rel.name,
                                    trailing: (rel.kind == .table || rel.kind == .partitioned) ? Fmt.rows(rel.estRows) : nil,
                                    selected: model.selectedDatabase == dbName && model.selectedRelationID == rel.id,
                                    expandable: false, expanded: false,
                                    muted: rel.kind == .function,
                                    onToggle: {},
                                    onSelect: { model.select(database: dbName, relation: rel) },
                                    onOpen: { model.openTable(database: dbName, relation: rel) })
                        }
                    }
                }
                if schemaGroups.isEmpty {
                    inlineRow(depth: 2) {
                        Text(filter.isEmpty ? "No tables." : "No matches.")
                            .font(.ui(12)).foregroundColor(pal.textMuted)
                    }
                }
            }
        }
    }

    @ViewBuilder private func inlineRow<Content: View>(depth: Int, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Spacer().frame(width: CGFloat(depth) * 14 + 24)
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 26)
    }

    private func toggleSchema(_ key: String) {
        if collapsedSchemas.contains(key) { collapsedSchemas.remove(key) } else { collapsedSchemas.insert(key) }
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).scaleEffect(0.7)
            Text("Loading schema…").font(.ui(12)).foregroundColor(pal.textMuted)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func errorRow(_ err: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundColor(pal.danger)
            Text(err).font(.mono(11)).foregroundColor(pal.danger)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

// MARK: - Tree row

private struct TreeRow: View {
    @Environment(\.palette) var pal
    let depth: Int
    let icon: String
    let label: String
    let trailing: String?
    let selected: Bool
    let expandable: Bool
    let expanded: Bool
    var muted: Bool = false
    let onToggle: () -> Void
    let onSelect: () -> Void
    var onOpen: () -> Void = {}

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            // indentation
            Spacer().frame(width: CGFloat(depth) * 14)

            // chevron
            if expandable {
                Button(action: onToggle) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(pal.textFaint)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 12)
            }

            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(selected ? pal.accent : pal.textMuted)
                .frame(width: 16)

            Text(label)
                .font(depth == 0 ? .ui(12.5, weight: .semibold) : .ui(12.5))
                .foregroundColor(muted ? pal.textFaint : (selected ? pal.textPrimary : pal.textPrimary))
                .lineLimit(1)

            Spacer(minLength: 4)

            if let trailing {
                Text(trailing)
                    .font(.mono(10.5))
                    .foregroundColor(pal.textFaint)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusSM, style: .continuous)
                .fill(selected ? pal.surfaceSelected : (hovering ? pal.surfaceHover : .clear))
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpen)
        .onTapGesture(count: 1, perform: onSelect)
        .onHover { hovering = $0 }
    }
}

// MARK: - Center: welcome / table data

private struct CenterPane: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.palette) var pal

    private let defaultCellWidth: CGFloat = 180
    private let headerHeight: CGFloat = 44
    /// User-resized column widths, keyed "tabID|columnName".
    @State private var colWidths: [String: CGFloat] = [:]

    private func colKey(_ tab: DataTab, _ name: String) -> String { "\(tab.id)|\(name)" }
    private func colWidth(_ tab: DataTab, _ name: String) -> CGFloat { colWidths[colKey(tab, name)] ?? defaultCellWidth }

    var body: some View {
        VStack(spacing: 0) {
            if model.tabs.isEmpty {
                welcome
            } else {
                tabBar
                Divider().overlay(pal.borderDefault)
                if let tab = model.activeTab {
                    contextBar(tab)
                    Divider().overlay(pal.borderSubtle)
                    content(tab)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(pal.surfaceRaised)
    }

    // MARK: Tabs

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(model.tabs) { tab in
                    TabChip(tab: tab,
                            active: tab.id == model.activeTabID,
                            onSelect: { model.focusTab(tab.id) },
                            onClose: { model.closeTab(tab.id) })
                }
            }
        }
        .frame(height: Metrics.tabbarHeight)
        .background(pal.surfacePanel)
    }

    private func contextBar(_ tab: DataTab) -> some View {
        HStack(spacing: 8) {
            Text(tab.relation.schema).font(.mono(11.5)).foregroundColor(pal.textMuted)
            Text("/").font(.mono(11.5)).foregroundColor(pal.textFaint)
            Text(tab.relation.name).font(.mono(11.5, weight: .semibold)).foregroundColor(pal.textPrimary)
            Badge(text: kindLabel(tab.relation.kind), color: pal.textMuted)
            Spacer()
            if !tab.loading && tab.error == nil {
                Badge(text: "\(tab.rows.count) rows", color: pal.textMuted, mono: true)
            }
            Button { model.reloadTab(tab.id) } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12)).foregroundColor(pal.textMuted)
                    .frame(width: 26, height: 24)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(pal.surfaceRaised)
    }

    // MARK: Active tab content

    @ViewBuilder private func content(_ tab: DataTab) -> some View {
        if tab.loading {
            center { ProgressView().controlSize(.small); Text("Loading data…").font(.ui(13)).foregroundColor(pal.textMuted) }
        } else if let err = tab.error {
            center { Image(systemName: "exclamationmark.triangle").font(.system(size: 22)).foregroundColor(pal.danger)
                     Text(err).font(.mono(12)).foregroundColor(pal.danger).multilineTextAlignment(.center) }
        } else if tab.columns.isEmpty {
            center { Image(systemName: "tablecells").font(.system(size: 22)).foregroundColor(pal.textFaint)
                     Text("No rows").font(.ui(13)).foregroundColor(pal.textMuted) }
        } else {
            dataGrid(tab)
        }
    }

    private func dataGrid(_ tab: DataTab) -> some View {
        let families = tab.columns.map { TypeFamily.from(tab.info(for: $0)?.type ?? "") }
        let widths = tab.columns.map { colWidth(tab, $0) }
        return GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section(header: gridHeaderRow(tab, widths: widths)) {
                        ForEach(Array(tab.rows.enumerated()), id: \.offset) { _, row in
                            gridRow(row, widths: widths, families: families)
                        }
                    }
                }
                // Fill at least the viewport so short content top-aligns instead of
                // sinking to the bottom (macOS combined-axis ScrollView quirk).
                .frame(minHeight: geo.size.height, alignment: .top)
            }
        }
    }

    private func gridHeaderRow(_ tab: DataTab, widths: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(tab.columns.enumerated()), id: \.offset) { idx, name in
                let info = tab.info(for: name)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if info?.isPK == true {
                            Image(systemName: "key.fill").font(.system(size: 8)).foregroundColor(pal.amber500)
                        }
                        Text(name)
                            .font(.mono(11.5, weight: .bold))
                            .foregroundColor(pal.textPrimary)
                            .lineLimit(1)
                    }
                    if let type = info?.type {
                        Text(shortType(type))
                            .font(.mono(9.5, weight: .medium))
                            .foregroundColor(pal.typeColors(TypeFamily.from(type)).fg)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(width: widths[idx], height: headerHeight, alignment: .leading)
                .overlay(alignment: .trailing) {
                    ColumnResizeHandle(width: widths[idx]) { newWidth in
                        colWidths[colKey(tab, name)] = newWidth
                    }
                }
            }
        }
        .background(pal.surfacePanel)
        .overlay(Divider().overlay(pal.borderDefault), alignment: .bottom)
    }

    private func gridRow(_ row: [String?], widths: [CGFloat], families: [TypeFamily]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(row.enumerated()), id: \.offset) { idx, value in
                let numeric = idx < families.count && families[idx] == .numeric
                Group {
                    if let value {
                        Text(value)
                            .font(.mono(12.5))
                            .foregroundColor(pal.textPrimary)
                    } else {
                        Text("NULL")
                            .font(.mono(11))
                            .foregroundColor(pal.textFaint)
                            .italic()
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 10)
                .frame(width: idx < widths.count ? widths[idx] : defaultCellWidth,
                       height: Metrics.rowHeight, alignment: numeric ? .trailing : .leading)
                .overlay(Divider().overlay(pal.borderSubtle), alignment: .trailing)
            }
        }
        .overlay(Divider().overlay(pal.borderSubtle), alignment: .bottom)
    }

    /// Compact a Postgres type for the header badge, e.g. "character varying" -> "varchar".
    private func shortType(_ t: String) -> String {
        switch t.lowercased() {
        case "character varying": return "varchar"
        case "timestamp with time zone": return "timestamptz"
        case "timestamp without time zone": return "timestamp"
        case "double precision": return "float8"
        case "boolean": return "bool"
        case "integer": return "int4"
        case "bigint": return "int8"
        default: return t
        }
    }

    private var welcome: some View {
        VStack(spacing: 12) {
            Image(systemName: "hexagon.fill")
                .font(.system(size: 34))
                .foregroundColor(pal.accent)
            Text("Welcome to Tusk")
                .font(.ui(17, weight: .semibold))
                .foregroundColor(pal.textPrimary)
            VStack(spacing: 4) {
                Text("Single-click an object in the explorer to inspect it.")
                Text("Double-click a table to open it in a new tab.")
            }
            .font(.ui(12.5))
            .foregroundColor(pal.textMuted)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func center<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 10) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func kindLabel(_ k: DBObjectKind) -> String {
        switch k {
        case .table: return "table"
        case .view: return "view"
        case .matview: return "materialized view"
        case .partitioned: return "partitioned"
        default: return "object"
        }
    }
}

// MARK: - Column resize handle (sits on a header cell's trailing edge)

private struct ColumnResizeHandle: View {
    @Environment(\.palette) var pal
    let width: CGFloat
    let onChange: (CGFloat) -> Void

    @State private var startWidth: CGFloat?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 9)
            .overlay(Rectangle().fill(hovering ? pal.accent : pal.borderSubtle).frame(width: hovering ? 2 : 1))
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = startWidth ?? width
                        if startWidth == nil { startWidth = base }
                        onChange(min(max(base + Double(value.translation.width), 60), 800))
                    }
                    .onEnded { _ in startWidth = nil }
            )
    }
}

// MARK: - Center: one open tab

private struct TabChip: View {
    @Environment(\.palette) var pal
    let tab: DataTab
    let active: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: tab.relation.kind.iconName)
                .font(.system(size: 11))
                .foregroundColor(active ? pal.accent : pal.textFaint)
            Text(tab.relation.name)
                .font(.ui(12))
                .foregroundColor(active ? pal.textPrimary : pal.textMuted)
                .lineLimit(1)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(pal.textMuted)
                    .frame(width: 15, height: 15)
                    .background(Circle().fill(hovering ? pal.surfaceHover : .clear))
            }
            .buttonStyle(.plain)
            .opacity(hovering || active ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .frame(height: Metrics.tabbarHeight)
        .frame(maxWidth: 190)
        .background(active ? pal.surfaceRaised : pal.surfacePanel)
        .overlay(alignment: .top) {
            Rectangle().fill(active ? pal.accent : Color.clear).frame(height: 2)
        }
        .overlay(Divider().overlay(pal.borderSubtle), alignment: .trailing)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }
}

private struct ColumnRow: View {
    @Environment(\.palette) var pal
    let col: ColumnInfo
    let zebra: Bool

    var body: some View {
        HStack(spacing: 10) {
            // key glyph
            Group {
                if col.isPK {
                    Image(systemName: "key.fill").font(.system(size: 11)).foregroundColor(pal.amber500)
                } else if col.isFK {
                    Image(systemName: "link").font(.system(size: 11)).foregroundColor(pal.textFaint)
                } else {
                    Spacer().frame(width: 12)
                }
            }
            .frame(width: 14)

            Text(col.name)
                .font(.mono(12.5))
                .foregroundColor(pal.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 8)

            if !col.notNull {
                Text("null")
                    .font(.mono(10))
                    .foregroundColor(pal.textFaint)
            }
            TypeBadge(type: col.type)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusSM, style: .continuous)
                .fill(zebra ? pal.surfaceHover.opacity(0.5) : .clear)
        )
    }
}

// MARK: - Right info rail (selection-driven inspector)

private struct InfoRail: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.palette) var pal

    let width: CGFloat

    var body: some View {
        Group {
            switch model.inspector {
            case .server:              connectionInspector
            case .database(let name):  databaseInspector(name)
            case .relation:            tableInspector
            }
        }
        .frame(width: width)
        .background(pal.surfacePanel)
    }

    // MARK: Connection

    private var connectionInspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            railHeader("bolt.horizontal.circle", "Connection")
            VStack(alignment: .leading, spacing: 10) {
                infoRow("Name", model.activeConn?.name ?? "—", mono: false)
                infoRow("Host", model.activeConn?.hostPort ?? "—")
                infoRow("User", model.activeConn?.user ?? "—")
                infoRow("SSL", model.activeConn?.sslMode ?? "—")
            }
            .padding(14)
            sectionLabel("SERVER")
            HStack(spacing: 8) {
                stat("\(model.databases.count)", "databases")
            }
            .padding(.horizontal, 14)
            Spacer()
        }
    }

    // MARK: Database

    private func databaseInspector(_ name: String) -> some View {
        let snap = model.snapshots[name]
        return VStack(alignment: .leading, spacing: 0) {
            railHeader("cylinder.split.1x2", "Database")
            VStack(alignment: .leading, spacing: 10) {
                infoRow("Name", name)
                infoRow("Server", model.activeConn?.hostPort ?? "—")
            }
            .padding(14)
            sectionLabel("OVERVIEW")
            if snap == nil && model.loadingDatabases.contains(name) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text("Loading…").font(.ui(12)).foregroundColor(pal.textMuted)
                }
                .padding(.horizontal, 14)
            } else {
                HStack(spacing: 8) {
                    stat("\(schemaCount(snap))", "schemas")
                    stat("\(tableCount(snap))", "tables")
                    stat("\(viewCount(snap))", "views")
                }
                .padding(.horizontal, 14)
            }
            Spacer()
        }
    }

    // MARK: Table

    private var tableInspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            railHeader("tablecells", "Table")
            if let rel = model.selectedRelation {
                VStack(alignment: .leading, spacing: 10) {
                    infoRow("Schema", rel.schema)
                    infoRow("Name", rel.name)
                    if rel.kind == .table || rel.kind == .partitioned {
                        infoRow("Est. rows", "~\(Fmt.rows(rel.estRows))")
                    }
                }
                .padding(14)
            }
            HStack {
                Text("COLUMNS")
                    .font(.ui(10, weight: .semibold)).tracking(0.6)
                    .foregroundColor(pal.textFaint)
                Spacer()
                Text("\(model.columns.count)")
                    .font(.mono(11)).foregroundColor(pal.textFaint)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)

            if model.loadingColumns {
                inlineNote { ProgressView().controlSize(.small).scaleEffect(0.7)
                             Text("Loading columns…").font(.ui(12)).foregroundColor(pal.textMuted) }
            } else if model.columns.isEmpty {
                inlineNote { Text("No columns").font(.ui(12)).foregroundColor(pal.textMuted) }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.columns.enumerated()), id: \.element.id) { idx, col in
                            ColumnRow(col: col, zebra: idx % 2 == 1)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    // MARK: Building blocks

    private func railHeader(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 14)).foregroundColor(pal.textMuted)
            Text(title).font(.ui(13, weight: .semibold)).foregroundColor(pal.textPrimary)
            Spacer()
            StatusDot(status: "connected", size: 7)
        }
        .padding(.horizontal, 14)
        .frame(height: Metrics.toolbarHeight)
        .overlay(Divider().overlay(pal.borderSubtle), alignment: .bottom)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.ui(10, weight: .semibold)).tracking(0.6)
            .foregroundColor(pal.textFaint)
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 8)
    }

    @ViewBuilder private func inlineNote<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 14)
        Spacer()
    }

    private func schemaCount(_ snap: DBSnapshot?) -> Int {
        Set(snap?.relations.map { $0.schema } ?? []).count
    }
    private func tableCount(_ snap: DBSnapshot?) -> Int {
        snap?.relations.filter { $0.kind == .table || $0.kind == .partitioned }.count ?? 0
    }
    private func viewCount(_ snap: DBSnapshot?) -> Int {
        snap?.relations.filter { $0.kind == .view || $0.kind == .matview }.count ?? 0
    }

    private func infoRow(_ label: String, _ value: String, mono: Bool = true) -> some View {
        HStack {
            Text(label).font(.ui(12)).foregroundColor(pal.textMuted)
            Spacer()
            Text(value)
                .font(mono ? .mono(11.5) : .ui(12, weight: .medium))
                .foregroundColor(pal.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.ui(18, weight: .semibold)).foregroundColor(pal.textPrimary)
            Text(label).font(.ui(10.5)).foregroundColor(pal.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusMD, style: .continuous)
                .fill(pal.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusMD, style: .continuous)
                .strokeBorder(pal.borderSubtle, lineWidth: 1)
        )
    }
}
