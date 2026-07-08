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
                          schema: model.schemaIndex(for: c.database),
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
            StatusDot(status: model.connectionStatus, size: 7)
            Text(model.activeConn?.hostPort ?? "—").font(.mono(11)).foregroundColor(pal.textSecondary)
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
                       onExpand: { col, val in expanded = ExpandedValue(column: col, value: val) })
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
    var onExpand: ((_ column: String, _ value: String) -> Void)? = nil

    private let defaultCellWidth: CGFloat = 180
    private let headerHeight: CGFloat = 44
    @State private var colWidths: [String: CGFloat] = [:]
    @State private var hover: String? = nil   // "r|c"

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
    }

    private func headerRow(widths: [CGFloat]) -> some View {
        HStack(spacing: 0) {
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
                        Button { onExpand?(name, value) } label: {
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
                .onTapGesture(count: 2) { if expandable, let value { onExpand?(name, value) } }
            }
        }
        .overlay(Divider().overlay(pal.borderSubtle), alignment: .bottom)
    }

    /// JSON/JSONB, or text long enough (or content that looks like JSON) to be worth a viewer.
    private func isExpandable(_ value: String, family: TypeFamily) -> Bool {
        if family == .json { return true }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) { return true }
        return value.count > 40
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
    let value: String
}

/// A modal popup that pretty-prints a JSON/JSONB cell (or shows long text), with
/// a copy button. Dismissed by the close button, the backdrop, or Escape.
struct CellValueViewer: View {
    @Environment(\.palette) var pal
    let value: ExpandedValue
    let onClose: () -> Void

    @State private var copied = false

    private var pretty: String {
        let raw = value.value
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: out, encoding: .utf8) else { return raw }
        return s
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea().onTapGesture(perform: onClose)
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "curlybraces").font(.system(size: 12)).foregroundColor(pal.accent)
                    Text(value.column).font(.mono(12.5, weight: .semibold)).foregroundColor(pal.textPrimary)
                    Spacer()
                    Button { copyValue() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10))
                            Text(copied ? "Copied" : "Copy").font(.ui(11.5))
                        }
                        .foregroundColor(pal.textSecondary)
                        .padding(.horizontal, 8).frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: Metrics.radiusSM).fill(pal.surfaceCard))
                        .overlay(RoundedRectangle(cornerRadius: Metrics.radiusSM).strokeBorder(pal.borderDefault, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                            .foregroundColor(pal.textMuted).frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12).frame(height: 42)
                .background(pal.surfacePanel)
                .overlay(Divider().overlay(pal.borderDefault), alignment: .bottom)

                ScrollView([.vertical, .horizontal]) {
                    Text(pretty)
                        .font(.mono(12))
                        .foregroundColor(pal.textPrimary)
                        .textSelection(.enabled)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(pal.surfaceInset)
            }
            .frame(width: 620, height: 460)
            .background(pal.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusLG, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Metrics.radiusLG, style: .continuous).strokeBorder(pal.borderDefault, lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 30, y: 16)
        }
    }

    private func copyValue() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pretty, forType: .string)
        copied = true
    }
}
