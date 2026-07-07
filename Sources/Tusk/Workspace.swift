import SwiftUI
import TuskCore

struct Workspace: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.palette) var pal

    var body: some View {
        VStack(spacing: 0) {
            TitleBar()
            HStack(spacing: 0) {
                SchemaSidebar()
                TableDetail()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                InfoRail()
            }
        }
        .background(pal.surfaceApp)
        .ignoresSafeArea(.container, edges: .top)
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
                                trailing: nil, selected: false, expandable: true, expanded: !serverCollapsed) {
                            serverCollapsed.toggle()
                        } onSelect: { serverCollapsed.toggle() }

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
                trailing: nil, selected: false, expandable: true, expanded: dbExpanded,
                muted: !isActive) {
            model.toggleDatabase(dbName)
        } onSelect: { model.toggleDatabase(dbName) }

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
                            expandable: true, expanded: expanded) {
                        toggleSchema(key)
                    } onSelect: { toggleSchema(key) }

                    if expanded {
                        ForEach(group.relations) { rel in
                            TreeRow(depth: 3, icon: rel.kind.iconName, label: rel.name,
                                    trailing: (rel.kind == .table || rel.kind == .partitioned) ? Fmt.rows(rel.estRows) : nil,
                                    selected: model.selectedDatabase == dbName && model.selectedRelationID == rel.id,
                                    expandable: false, expanded: false,
                                    muted: rel.kind == .function) {
                            } onSelect: {
                                model.select(database: dbName, relation: rel)
                            }
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
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }
}

// MARK: - Center: table detail

private struct TableDetail: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.palette) var pal

    var body: some View {
        VStack(spacing: 0) {
            if let rel = model.selectedRelation {
                header(rel)
                columnsHeader
                Divider().overlay(pal.borderSubtle)
                if model.loadingColumns {
                    center { ProgressView().controlSize(.small); Text("Loading columns…").font(.ui(13)).foregroundColor(pal.textMuted) }
                } else if model.columns.isEmpty {
                    center { Image(systemName: "tablecells").font(.system(size: 22)).foregroundColor(pal.textFaint)
                             Text("No columns").font(.ui(13)).foregroundColor(pal.textMuted) }
                } else {
                    columnList
                }
            } else {
                emptyState
            }
        }
        .background(pal.surfaceRaised)
    }

    private func header(_ rel: Relation) -> some View {
        HStack(spacing: 10) {
            Image(systemName: rel.kind.iconName)
                .font(.system(size: 15))
                .foregroundColor(pal.textSecondary)
            Text(rel.schema).font(.ui(15)).foregroundColor(pal.textMuted)
            Text("/").font(.ui(15)).foregroundColor(pal.textFaint)
            Text(rel.name).font(.ui(15, weight: .semibold)).foregroundColor(pal.textPrimary)
            Badge(text: kindLabel(rel.kind), color: pal.textMuted)
            Spacer()
            if rel.kind == .table || rel.kind == .partitioned {
                Badge(text: "~\(Fmt.rows(rel.estRows)) rows", color: pal.textMuted, mono: true)
            }
            Button { model.refreshSchema() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 13)).foregroundColor(pal.textMuted)
                    .frame(width: 28, height: 26)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(height: Metrics.toolbarHeight)
        .background(pal.surfacePanel)
        .overlay(Divider().overlay(pal.borderSubtle), alignment: .bottom)
    }

    private var columnsHeader: some View {
        HStack {
            Text("COLUMNS")
                .font(.ui(10, weight: .semibold)).tracking(0.6)
                .foregroundColor(pal.textFaint)
            Spacer()
            Text("\(model.columns.count)")
                .font(.mono(11)).foregroundColor(pal.textFaint)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var columnList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(model.columns.enumerated()), id: \.element.id) { idx, col in
                    ColumnRow(col: col, zebra: idx % 2 == 1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: 30))
                .foregroundColor(pal.textFaint)
            Text("Select a table")
                .font(.ui(15, weight: .medium))
                .foregroundColor(pal.textSecondary)
            Text("Pick an object from the explorer to see its columns.")
                .font(.ui(12))
                .foregroundColor(pal.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func center<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 10) { content() }
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

// MARK: - Right info rail

private struct InfoRail: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.palette) var pal

    private var schemaCount: Int {
        Set(model.selectedSnapshot?.relations.map { $0.schema } ?? []).count
    }
    private var viewCount: Int {
        model.selectedSnapshot?.relations.filter { $0.kind == .view || $0.kind == .matview }.count ?? 0
    }
    private var tableCount: Int {
        model.selectedSnapshot?.relations.filter { $0.kind == .table || $0.kind == .partitioned }.count ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.horizontal.circle").font(.system(size: 14)).foregroundColor(pal.textMuted)
                Text("Connection").font(.ui(13, weight: .semibold)).foregroundColor(pal.textPrimary)
                Spacer()
                StatusDot(status: "connected", size: 7)
            }
            .padding(.horizontal, 14)
            .frame(height: Metrics.toolbarHeight)
            .overlay(Divider().overlay(pal.borderSubtle), alignment: .bottom)

            VStack(alignment: .leading, spacing: 10) {
                infoRow("Name", model.activeConn?.name ?? "—", mono: false)
                infoRow("Host", model.activeConn?.hostPort ?? "—")
                infoRow("Database", model.selectedDatabase ?? "—")
                infoRow("User", model.activeConn?.user ?? "—")
                infoRow("SSL", model.activeConn?.sslMode ?? "—")
            }
            .padding(14)

            Text("OVERVIEW")
                .font(.ui(10, weight: .semibold)).tracking(0.6)
                .foregroundColor(pal.textFaint)
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 8)

            HStack(spacing: 8) {
                stat("\(schemaCount)", "schemas")
                stat("\(tableCount)", "tables")
                stat("\(viewCount)", "views")
            }
            .padding(.horizontal, 14)

            Spacer()
        }
        .frame(width: 250)
        .background(pal.surfacePanel)
        .overlay(Divider().overlay(pal.borderDefault), alignment: .leading)
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
