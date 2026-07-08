import SwiftUI
import AppKit
import TuskCore

struct Workspace: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.palette) var pal

    @AppStorage("tusk.railWidth") private var railWidth: Double = 250
    @AppStorage("tusk.sidebarWidth") private var sidebarWidth: Double = 248
    @AppStorage("tusk.terminalHeight") private var terminalHeight: Double = 300

    var body: some View {
        VStack(spacing: 0) {
            TitleBar()
            HStack(spacing: 0) {
                SchemaSidebar(width: CGFloat(sidebarWidth))
                ResizeHandle(width: $sidebarWidth, range: 200...480, paneOnLeft: true)
                VStack(spacing: 0) {
                    CenterPane()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if model.showTerminal {
                        TerminalResizeBar(height: $terminalHeight, range: 140...640)
                        ClaudeTerminalPanel()
                            .frame(height: CGFloat(terminalHeight))
                    }
                }
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
    /// true: the resized pane sits to the handle's left (drag right widens it);
    /// false: the pane sits to the handle's right (drag left widens it).
    var paneOnLeft: Bool = false

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
                        let delta = Double(value.translation.width)
                        let proposed = paneOnLeft ? base + delta : base - delta
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

            // Claude Code terminal toggle
            Button {
                model.toggleTerminal()
            } label: {
                HStack(spacing: 6) {
                    ClaudeMark(size: 13)
                    Text("Claude Code")
                        .font(.ui(12))
                        .foregroundColor(model.showTerminal ? pal.accent : pal.textSecondary)
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.radiusSM, style: .continuous)
                        .fill(model.showTerminal ? pal.accent.opacity(0.12) : pal.surfaceCard)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.radiusSM, style: .continuous)
                        .strokeBorder(model.showTerminal ? pal.accent.opacity(0.35) : pal.borderDefault, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

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
                    StatusDot(status: model.connectionStatus, size: 7)
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
        // Vertically center the real macOS traffic lights in this 38pt bar so they
        // line up with the "Tusk" brand mark (they'd otherwise sit ~5pt higher).
        .background(TrafficLightAligner(centerFromTop: 19))
    }
}

// MARK: - Traffic light vertical alignment

/// Repositions the standard window buttons so their vertical center sits
/// `centerFromTop` points below the top of the window, matching a custom-height
/// title bar. Reapplied whenever macOS re-lays the buttons out (resize, key,
/// full-screen transitions).
private struct TrafficLightAligner: NSViewRepresentable {
    let centerFromTop: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(centerFromTop: centerFromTop) }

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        context.coordinator.attach(to: v)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.reposition()
    }

    final class Coordinator {
        let centerFromTop: CGFloat
        private weak var view: NSView?
        private var observers: [NSObjectProtocol] = []

        init(centerFromTop: CGFloat) { self.centerFromTop = centerFromTop }

        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

        func attach(to view: NSView) {
            self.view = view
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didEndLiveResizeNotification,
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification,
            ]
            for name in names {
                let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.reposition()
                }
                observers.append(token)
            }
            DispatchQueue.main.async { [weak self] in self?.reposition() }
        }

        func reposition() {
            guard let window = view?.window else { return }
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                .compactMap { window.standardWindowButton($0) }
            guard let container = buttons.first?.superview else { return }
            for button in buttons {
                var frame = button.frame
                // Titlebar container's top edge coincides with the window top; place
                // the button's center `centerFromTop` down from there.
                frame.origin.y = container.bounds.height - centerFromTop - frame.height / 2
                button.frame = frame
            }
        }
    }
}

// MARK: - Schema sidebar (live object tree)

private struct SchemaSidebar: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.palette) var pal

    var width: CGFloat = 248
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
        .frame(width: width)
        .background(pal.surfacePanel)
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
            .contextMenu {
                Button {
                    model.openConsole(database: dbName)
                } label: { Label("New Query Console", systemImage: "chevron.left.forward.slash.chevron.right") }
            }

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
                                .contextMenu {
                                    Button {
                                        model.openTable(database: dbName, relation: rel)
                                    } label: { Label("Open Table", systemImage: "tablecells") }
                                    Button {
                                        model.openConsole(database: dbName,
                                                          seedSQL: "SELECT * FROM \(rel.schema).\(rel.name) LIMIT 100")
                                    } label: { Label("Query Console", systemImage: "chevron.left.forward.slash.chevron.right") }
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

    var body: some View {
        VStack(spacing: 0) {
            if model.tabs.isEmpty {
                welcome
            } else {
                tabBar
                Divider().overlay(pal.borderDefault)
                if let tab = model.activeTab {
                    switch tab {
                    case .data(let t):    dataTabView(t)
                    case .console(let c): ConsolePane(console: c).id(c.id)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(pal.surfaceRaised)
    }

    @ViewBuilder private func dataTabView(_ tab: DataTab) -> some View {
        contextBar(tab)
        Divider().overlay(pal.borderSubtle)
        content(tab)
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
            ResultGrid(gridID: tab.id, columns: tab.columns, columnInfos: tab.columnInfos, rows: tab.rows)
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

// MARK: - Center: one open tab

private struct TabChip: View {
    @Environment(\.palette) var pal
    let tab: WorkspaceTab
    let active: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    private var icon: String {
        switch tab {
        case .data(let t):   return t.relation.kind.iconName
        case .console:       return "chevron.left.forward.slash.chevron.right"
        }
    }
    private var label: String {
        switch tab {
        case .data(let t):      return t.relation.name
        case .console(let c):   return c.title.isEmpty ? "Query" : c.title
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(active ? pal.accent : pal.textFaint)
            Text(label)
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
            StatusDot(status: model.connectionStatus, size: 7)
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
