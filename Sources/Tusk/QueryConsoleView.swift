import SwiftUI
import TuskCore

// MARK: - Query console pane (editor + run + results)

/// The center-pane view for a `.console` tab: a syntax-highlighted SQL editor on
/// top, a DS query status bar, and the results grid below. Run with the button or
/// ⌘↵. Results render here whether the run came from the human or from Claude (MCP).
struct ConsolePane: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.palette) var pal
    let console: QueryConsole

    @AppStorage("tusk.consoleEditorHeight") private var editorHeight: Double = 220
    @State private var expanded: ExpandedValue?

    /// Read live from the model so MCP edits and runs reflect immediately.
    private var live: QueryConsole { model.console(console.id) ?? console }

    private var sqlBinding: Binding<String> {
        Binding(get: { model.console(console.id)?.sql ?? "" },
                set: { model.setConsoleSQL(console.id, sql: $0) })
    }

    var body: some View {
        let c = live
        VStack(spacing: 0) {
            toolbar(c)
            Divider().overlay(pal.borderSubtle)

            SQLEditorView(text: sqlBinding, isDark: model.isDark,
                          schema: model.schemaIndex(connId: c.connectionId, database: c.database),
                          onRun: { model.runConsole(console.id) })
                .frame(height: CGFloat(editorHeight))
                .background(pal.surfaceInset)

            EditorResizeBar(height: $editorHeight, range: 100...520)
            statusBar(c)
            resultsArea(c)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(pal.surfaceRaised)
        .overlay { if let e = expanded { CellValueViewer(value: e) { expanded = nil } } }
    }

    // MARK: Toolbar

    private func toolbar(_ c: QueryConsole) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "cylinder.split.1x2").font(.system(size: 11)).foregroundColor(pal.textMuted)
            Text(c.database).font(.mono(11.5, weight: .semibold)).foregroundColor(pal.textPrimary)
            if c.lastRunByClaude {
                HStack(spacing: 4) {
                    ClaudeMark(size: 11)
                    Text("last run by Claude").font(.ui(11)).foregroundColor(pal.textMuted)
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: Metrics.radiusXS).fill(pal.accent.opacity(0.10)))
            }
            Spacer()

            Button { model.setConsoleReadOnly(console.id, !c.readOnly) } label: {
                HStack(spacing: 5) {
                    Image(systemName: c.readOnly ? "lock.fill" : "lock.open").font(.system(size: 10))
                    Text("Read-only").font(.ui(11.5))
                }
                .foregroundColor(c.readOnly ? pal.accent : pal.textMuted)
                .padding(.horizontal, 8).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: Metrics.radiusSM).fill(c.readOnly ? pal.accent.opacity(0.12) : pal.surfaceCard))
                .overlay(RoundedRectangle(cornerRadius: Metrics.radiusSM).strokeBorder(c.readOnly ? pal.accent.opacity(0.35) : pal.borderDefault, lineWidth: 1))
            }
            .buttonStyle(.plain)

            TuskButton(title: "Run", icon: "play.fill", variant: .primary, size: .small, loading: c.running) {
                model.runConsole(console.id)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(pal.surfaceRaised)
    }

    // MARK: Status bar (DS QueryStatusBar)

    private func statusBar(_ c: QueryConsole) -> some View {
        let state = c.running ? "running" : (c.error != nil ? "error" : "idle")
        return HStack(spacing: 10) {
            StatusDot(status: model.status(for: c.connectionId), size: 7)
            Text(model.connection(for: c.connectionId)?.hostPort ?? "—").font(.mono(11)).foregroundColor(pal.textSecondary)
            Text("·").foregroundColor(pal.textFaint)
            Text(c.database).font(.mono(11)).foregroundColor(pal.syntax.table)
            Spacer()
            if let err = c.error {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.octagon.fill").font(.system(size: 10)).foregroundColor(pal.danger)
                    Text(err).font(.mono(11)).foregroundColor(pal.danger).lineLimit(1).truncationMode(.middle)
                }
            } else {
                if !c.running && !c.columns.isEmpty {
                    Text("\(c.rows.count) rows").font(.mono(11)).foregroundColor(pal.textSecondary)
                    Text("·").foregroundColor(pal.textFaint)
                }
                if let ms = c.elapsedMs, !c.running {
                    Text("\(ms) ms").font(.mono(11)).foregroundColor(pal.textSecondary)
                    Text("·").foregroundColor(pal.textFaint)
                }
                Text(state)
                    .font(.mono(11))
                    .foregroundColor(c.running ? pal.warning : pal.textFaint)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(pal.surfacePanel)
        .overlay(Divider().overlay(pal.borderDefault), alignment: .top)
    }

    // MARK: Results

    @ViewBuilder private func resultsArea(_ c: QueryConsole) -> some View {
        if c.running {
            centered { ProgressView().controlSize(.small); Text("Running…").font(.ui(13)).foregroundColor(pal.textMuted) }
        } else if c.error != nil {
            centered {
                Image(systemName: "exclamationmark.octagon").font(.system(size: 22)).foregroundColor(pal.danger)
                Text(c.error ?? "").font(.mono(12)).foregroundColor(pal.danger).multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        } else if c.columns.isEmpty {
            centered {
                Image(systemName: "chevron.left.forward.slash.chevron.right").font(.system(size: 22)).foregroundColor(pal.textFaint)
                Text("No results yet").font(.ui(13)).foregroundColor(pal.textMuted)
                Text("Write SQL above and press ⌘↵ to run.").font(.ui(12)).foregroundColor(pal.textFaint)
            }
        } else {
            ResultGrid(gridID: console.id, columns: c.columns, columnInfos: [], rows: c.rows,
                       onExpand: { col, type, val in expanded = ExpandedValue(column: col, type: type, value: val) })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func centered<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 10) { content() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Editor / results resize bar

private struct EditorResizeBar: View {
    @Environment(\.palette) var pal
    @Binding var height: Double
    let range: ClosedRange<Double>
    @State private var start: Double?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(pal.surfacePanel)
            .frame(height: 6)
            .overlay(Rectangle().fill(hovering ? pal.accent : pal.borderDefault).frame(height: hovering ? 2 : 1))
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        let base = start ?? height
                        if start == nil { start = base }
                        height = min(max(base + Double(v.translation.height), range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in start = nil }
            )
    }
}

// MARK: - Reusable result grid (DS DataGrid)

/// A spreadsheet-style results grid shared by data tabs and query consoles: sticky
/// header with type badges, resizable columns, null/numeric formatting, and an
/// expand affordance on JSON / long-text cells that opens a value viewer.
struct ResultGrid: View {
    @Environment(\.palette) var pal

    let gridID: String
    let columns: [String]
    let columnInfos: [ColumnInfo]
    let rows: [[String?]]
    var onExpand: ((_ column: String, _ type: String, _ value: String) -> Void)? = nil
    /// When set, each row shows a trash affordance that (after confirmation) calls
    /// this with the row index. Left nil for read-only grids (e.g. query consoles).
    var onDeleteRow: ((_ rowIndex: Int) -> Void)? = nil

    private let defaultCellWidth: CGFloat = 180
    private let headerHeight: CGFloat = 44
    private let gutterWidth: CGFloat = 36
    @State private var colWidths: [String: CGFloat] = [:]
    @State private var hover: String? = nil   // "r|c"
    @State private var hoverRow: Int? = nil
    @State private var pendingDelete: Int? = nil

    private var hasRowActions: Bool { onDeleteRow != nil }

    private func info(_ name: String) -> ColumnInfo? { columnInfos.first { $0.name == name } }
    private func width(_ name: String) -> CGFloat { colWidths[name] ?? defaultCellWidth }

    var body: some View {
        let families = columns.map { TypeFamily.from(info($0)?.type ?? "") }
        let widths = columns.map { width($0) }
        return GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section(header: headerRow(widths: widths)) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                            bodyRow(r, row, widths: widths, families: families)
                        }
                    }
                }
                .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
            }
        }
        .confirmationDialog("Delete this row?", isPresented: deleteDialogBinding, titleVisibility: .visible) {
            Button("Delete Row", role: .destructive) {
                if let r = pendingDelete { onDeleteRow?(r) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This permanently deletes the row from the database and cannot be undone.")
        }
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private func headerRow(widths: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            if hasRowActions {
                Color.clear
                    .frame(width: gutterWidth, height: headerHeight)
                    .overlay(Divider().overlay(pal.borderDefault), alignment: .trailing)
            }
            ForEach(Array(columns.enumerated()), id: \.offset) { idx, name in
                let ci = info(name)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if ci?.isPK == true {
                            Image(systemName: "key.fill").font(.system(size: 8)).foregroundColor(pal.amber500)
                        }
                        Text(name).font(.mono(11.5, weight: .bold)).foregroundColor(pal.textPrimary).lineLimit(1)
                    }
                    if let type = ci?.type {
                        Text(shortType(type)).font(.mono(9.5, weight: .medium))
                            .foregroundColor(pal.typeColors(TypeFamily.from(type)).fg).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(width: widths[idx], height: headerHeight, alignment: .leading)
                .overlay(alignment: .trailing) {
                    ColumnResize(width: widths[idx]) { colWidths[name] = $0 }
                }
            }
        }
        .background(pal.surfacePanel)
        .overlay(Divider().overlay(pal.borderDefault), alignment: .bottom)
    }

    private func bodyRow(_ r: Int, _ row: [String?], widths: [CGFloat], families: [TypeFamily]) -> some View {
        HStack(spacing: 0) {
            if hasRowActions {
                // A tap-gesture view rather than a Button: a SwiftUI Button is an AppKit
                // control that installs its own hover tracking and steals the row's hover,
                // making the icon flicker away as the cursor reaches it. A gesture doesn't.
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(pal.danger)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: Metrics.radiusXS).fill(pal.danger.opacity(0.12)))
                    .overlay(RoundedRectangle(cornerRadius: Metrics.radiusXS).strokeBorder(pal.danger.opacity(0.30), lineWidth: 1))
                    .opacity(hoverRow == r ? 1 : 0)
                    .frame(width: gutterWidth, height: Metrics.rowHeight)
                    .overlay(Divider().overlay(pal.borderSubtle), alignment: .trailing)
                    .contentShape(Rectangle())
                    .onTapGesture { if hoverRow == r { pendingDelete = r } }
                    .help("Delete row")
            }
            ForEach(Array(row.enumerated()), id: \.offset) { idx, value in
                let name = idx < columns.count ? columns[idx] : "\(idx)"
                let family = idx < families.count ? families[idx] : .other
                let numeric = family == .numeric
                let cellW = idx < widths.count ? widths[idx] : defaultCellWidth
                let key = "\(r)|\(idx)"
                let expandable = value.map { isExpandable($0, family: family) } ?? false
                ZStack(alignment: .trailing) {
                    Group {
                        if let value {
                            Text(value).font(.mono(12.5)).foregroundColor(pal.textPrimary)
                        } else {
                            Text("NULL").font(.mono(11)).foregroundColor(pal.textFaint).italic()
                        }
                    }
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: numeric ? .trailing : .leading)

                    if expandable, hover == key, let value {
                        Button { onExpand?(name, info(name)?.type ?? "", value) } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(pal.textMuted)
                                .frame(width: 18, height: 18)
                                .background(RoundedRectangle(cornerRadius: Metrics.radiusXS).fill(pal.surfaceRaised))
                                .overlay(RoundedRectangle(cornerRadius: Metrics.radiusXS).strokeBorder(pal.borderDefault, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .frame(width: cellW, height: Metrics.rowHeight)
                .overlay(Divider().overlay(pal.borderSubtle), alignment: .trailing)
                .contentShape(Rectangle())
                .onHover { hover = $0 ? key : (hover == key ? nil : hover) }
                .onTapGesture(count: 2) { if expandable, let value { onExpand?(name, info(name)?.type ?? "", value) } }
            }
        }
        .overlay(Divider().overlay(pal.borderSubtle), alignment: .bottom)
        .onHover { inside in
            if inside { hoverRow = r } else if hoverRow == r { hoverRow = nil }
        }
    }

    /// JSON/JSONB, a full timestamp, or text long enough (or content that looks like
    /// JSON) to be worth a viewer. Scalar types that always fit — numbers, bools,
    /// uuids — never get an expander even when long.
    private func isExpandable(_ value: String, family: TypeFamily) -> Bool {
        if family == .json { return true }
        if family == .temporal { return DatetimeParts.parse(value) != nil }
        if family == .numeric || family == .bool || family == .uuid { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) { return true }
        return value.count > 20
    }

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
}

private struct ColumnResize: View {
    @Environment(\.palette) var pal
    let width: CGFloat
    let onChange: (CGFloat) -> Void
    @State private var start: CGFloat?
    @State private var hovering = false

    var body: some View {
        Rectangle().fill(Color.clear).frame(width: 9)
            .overlay(Rectangle().fill(hovering ? pal.accent : pal.borderSubtle).frame(width: hovering ? 2 : 1))
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { v in
                    let base = start ?? width
                    if start == nil { start = base }
                    onChange(min(max(base + Double(v.translation.width), 60), 800))
                }
                .onEnded { _ in start = nil })
    }
}

// MARK: - Cell value viewer (JSONB / long-text popup)

struct ExpandedValue: Identifiable, Equatable {
    let id = UUID()
    let column: String
    let type: String
    let value: String
}

/// The three shapes the value viewer can take, chosen from the column's type and
/// content: pretty-printed JSON, a structured read-only datetime breakdown, or
/// wrapped long text.
private enum ViewerKind { case json, datetime, text }

/// A modal popup that inspects a single cell: pretty-prints JSON/JSONB, breaks a
/// timestamp into its date/time parts, or shows long text with a character count.
/// Read-only, with a copy button. Dismissed by the close button, backdrop, or Escape.
struct CellValueViewer: View {
    @Environment(\.palette) var pal
    let value: ExpandedValue
    let onClose: () -> Void

    @State private var copied = false
    @State private var contentSize: CGSize = .zero

    private var kind: ViewerKind {
        let family = TypeFamily.from(value.type)
        if family == .json { return .json }
        if family == .temporal, DatetimeParts.parse(value.value) != nil { return .datetime }
        let trimmed = value.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) { return .json }
        return .text
    }

    // The card width is fixed for the datetime/text views (which wrap or lay out to a
    // set width) and hugs the measured content, up to a cap, for JSON.
    private var cardWidth: CGFloat {
        switch kind {
        case .json: return min(max(contentSize.width, 340), 760)
        case .datetime: return 292
        case .text: return 460
        }
    }
    private var scrollHeight: CGFloat {
        switch kind {
        case .json: return min(max(contentSize.height, 40), 560)
        case .text: return min(max(contentSize.height, 40), 340)
        case .datetime: return 0
        }
    }

    private var headerIcon: String {
        switch kind {
        case .json: return "curlybraces"
        case .datetime: return "calendar"
        case .text: return "text.alignleft"
        }
    }
    private var iconColor: Color {
        switch kind {
        case .json: return pal.accent
        case .datetime: return pal.typeColors(.temporal).fg
        case .text: return pal.textSecondary
        }
    }

    private var pretty: String {
        let raw = value.value
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: out, encoding: .utf8) else { return raw }
        return s
    }

    /// Text placed on the pasteboard by the copy button (pretty JSON, else raw value).
    private var copyText: String { kind == .json ? pretty : value.value }

    var body: some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea().onTapGesture(perform: onClose)
            VStack(spacing: 0) {
                header
                content
            }
            .frame(width: cardWidth)
            .onPreferenceChange(CellContentSizeKey.self) { contentSize = $0 }
            .background(pal.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusLG, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Metrics.radiusLG, style: .continuous).strokeBorder(pal.borderDefault, lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 30, y: 16)
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: headerIcon).font(.system(size: 13)).foregroundColor(iconColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(value.column).font(.mono(12.5, weight: .semibold))
                    .foregroundColor(pal.textPrimary).lineLimit(1).fixedSize()
                if !value.type.isEmpty {
                    Text(shortType(value.type)).font(.mono(9.5, weight: .medium))
                        .foregroundColor(pal.typeColors(TypeFamily.from(value.type)).fg).lineLimit(1).fixedSize()
                }
            }
            Spacer(minLength: 8)
            Text("READ-ONLY")
                .font(.ui(9.5, weight: .medium)).tracking(0.4).fixedSize()
                .foregroundColor(pal.textFaint)
            Button { copyValue() } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11))
                    .foregroundColor(copied ? pal.success : pal.textSecondary)
                    .frame(width: 26, height: 24)
                    .background(RoundedRectangle(cornerRadius: Metrics.radiusSM).fill(pal.surfaceCard))
                    .overlay(RoundedRectangle(cornerRadius: Metrics.radiusSM).strokeBorder(pal.borderDefault, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help(copied ? "Copied" : "Copy value")
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .foregroundColor(pal.textMuted).frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).frame(height: 48)
        .background(pal.surfacePanel)
        .overlay(Divider().overlay(pal.borderDefault), alignment: .bottom)
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .json: jsonBody
        case .datetime: datetimeBody
        case .text: textBody
        }
    }

    private var jsonBody: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(pretty)
                .font(.mono(12))
                .foregroundColor(pal.textPrimary)
                .textSelection(.enabled)
                .padding(14)
                .fixedSize()
                .background(GeometryReader { g in
                    Color.clear.preference(key: CellContentSizeKey.self, value: g.size)
                })
        }
        .frame(width: cardWidth, height: scrollHeight)
        .background(pal.surfaceInset)
    }

    private var textBody: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                Text(value.value)
                    .font(.mono(13))
                    .foregroundColor(pal.textPrimary)
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: CellContentSizeKey.self, value: g.size)
                    })
            }
            .frame(height: scrollHeight)
            .background(pal.surfaceInset)

            HStack {
                Text("\(value.value.count) chars")
                    .font(.mono(11.5)).foregroundColor(pal.textFaint)
                Spacer()
            }
            .padding(.horizontal, 14).frame(height: 34)
            .background(pal.surfacePanel)
            .overlay(Divider().overlay(pal.borderSubtle), alignment: .top)
        }
    }

    @ViewBuilder private var datetimeBody: some View {
        if let p = DatetimeParts.parse(value.value) {
            VStack(alignment: .leading, spacing: 11) {
                labeledRow("DATE") {
                    HStack(spacing: 7) {
                        dtField(String(p.day), width: 40, mono: true)
                        dtField(p.monthName, width: 92)
                        dtField(String(p.year), width: 54, mono: true)
                    }
                }
                labeledRow("TIME") {
                    HStack(spacing: 5) {
                        dtField(pad2(p.hour), width: 44, mono: true)
                        dtColon
                        dtField(pad2(p.minute), width: 44, mono: true)
                        dtColon
                        dtField(pad2(p.second), width: 44, mono: true)
                    }
                }
                if !p.frac.isEmpty || !p.tz.isEmpty {
                    HStack(spacing: 18) {
                        if !p.tz.isEmpty { dtCaption("UTC OFFSET", p.tz) }
                        if !p.frac.isEmpty { dtCaption("FRACTION", ".\(p.frac)") }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(14)
            .background(pal.surfaceInset)
        }
    }

    private func labeledRow<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.ui(9.5, weight: .medium)).tracking(0.5).foregroundColor(pal.textMuted)
            content()
        }
    }

    private var dtColon: some View {
        Text(":").font(.mono(13, weight: .medium)).foregroundColor(pal.textFaint)
    }

    /// A boxed, read-only datetime field pinned to a compact fixed width.
    private func dtField(_ text: String, width: CGFloat, mono: Bool = false) -> some View {
        Text(text)
            .font(mono ? .mono(13) : .ui(13))
            .foregroundColor(pal.textPrimary)
            .lineLimit(1).minimumScaleFactor(0.75)
            .padding(.horizontal, 6)
            .frame(width: width, height: 27)
            .background(RoundedRectangle(cornerRadius: Metrics.radiusSM, style: .continuous).fill(pal.surfaceApp))
            .overlay(RoundedRectangle(cornerRadius: Metrics.radiusSM, style: .continuous).strokeBorder(pal.borderDefault, lineWidth: 1))
    }

    private func dtCaption(_ label: String, _ val: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.ui(9.5, weight: .medium)).tracking(0.5).foregroundColor(pal.textMuted)
            Text(val).font(.mono(12.5)).foregroundColor(pal.textSecondary)
        }
    }

    private func pad2(_ n: Int) -> String { String(format: "%02d", n) }

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

    private func copyValue() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
        copied = true
    }
}

/// The parsed fields of a Postgres timestamp, used both to gate the expand
/// affordance on temporal cells and to render the datetime breakdown view.
struct DatetimeParts {
    let year: Int, month: Int, day: Int
    let hour: Int, minute: Int, second: Int
    let frac: String, tz: String

    private static let monthNames = ["January", "February", "March", "April", "May", "June",
                                     "July", "August", "September", "October", "November", "December"]
    var monthName: String { (1...12).contains(month) ? DatetimeParts.monthNames[month - 1] : String(month) }

    private static let regex = try! NSRegularExpression(
        pattern: #"^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?\s*([+-]\d{2}(?::?\d{2})?|Z)?$"#)

    static func parse(_ raw: String) -> DatetimeParts? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let m = Self.regex.firstMatch(in: s, options: [], range: range) else { return nil }
        func grp(_ i: Int) -> String {
            guard let r = Range(m.range(at: i), in: s) else { return "" }
            return String(s[r])
        }
        guard let y = Int(grp(1)), let mo = Int(grp(2)), let d = Int(grp(3)),
              let h = Int(grp(4)), let mi = Int(grp(5)), let se = Int(grp(6)) else { return nil }
        return DatetimeParts(year: y, month: mo, day: d, hour: h, minute: mi, second: se, frac: grp(7), tz: grp(8))
    }
}

/// Measures the natural size of the viewer's content so the popup can hug it.
private struct CellContentSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        value = CGSize(width: max(value.width, next.width), height: max(value.height, next.height))
    }
}
