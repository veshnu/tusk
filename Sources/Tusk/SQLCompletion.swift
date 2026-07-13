import SwiftUI
import AppKit
import TuskCore

// MARK: - SQL dialect vocabulary (shared by highlighter + completion)

enum SQLDialect {
    static let keywordList: [String] = ("select from where group by order limit offset insert into values update set "
        + "delete join left right inner outer full on as and or not null is in like ilike between distinct having "
        + "union all with recursive case when then else end asc desc explain analyze begin commit rollback true false "
        + "create table view index alter drop add column primary key foreign references default cascade returning "
        + "using natural cross exists any some array").split(separator: " ").map(String.init)

    static let functionList: [String] = ("count sum avg min max coalesce now current_timestamp current_date date_trunc "
        + "extract lower upper length substring concat array_agg json_agg jsonb_build_object row_number rank "
        + "generate_series nullif greatest least cast to_char to_timestamp string_agg unnest").split(separator: " ").map(String.init)

    static let keywords = Set(keywordList)
    static let functions = Set(functionList)
    static let booleans: Set<String> = ["true", "false", "null"]
}

// MARK: - Schema index (completion data source)

/// A snapshot of the schema a console can complete against: tables and, where
/// known, their columns. Built by `AppModel` from its live snapshots + a column
/// cache and handed to the editor.
struct SchemaIndex: Equatable {
    struct Col: Equatable { let name: String; let type: String; let pk: Bool; let fk: Bool }
    struct Tbl: Equatable { let name: String; let schema: String; let kind: String }

    var tables: [Tbl] = []
    /// Columns keyed by BOTH bare "table" and qualified "schema.table" (lowercased).
    var columnsByTable: [String: [Col]] = [:]

    func columns(forTableToken token: String) -> [Col]? {
        columnsByTable[token.lowercased()]
    }
}

// MARK: - Completion item

enum CompletionKind: String { case keyword, function, table, view, schema, column, snippet }

struct Completion: Equatable {
    let label: String
    let kind: CompletionKind
    var type: String? = nil
    var detail: String? = nil
    var pk: Bool = false
}

// MARK: - Completion engine (pure)

enum SQLCompletionEngine {
    /// Compute completions for `text` at a UTF-16 caret offset.
    /// Returns the candidate list plus the partial-word `query` (for prefix emphasis)
    /// and the NSRange the accepted completion should replace.
    static func compute(text: String, caret: Int, schema: SchemaIndex)
        -> (items: [Completion], query: String, replace: NSRange) {
        let ns = text as NSString
        let clampedCaret = max(0, min(caret, ns.length))

        // Walk back over identifier characters to find the partial word.
        var start = clampedCaret
        while start > 0, isIdentChar(ns.character(at: start - 1)) { start -= 1 }
        let query = ns.substring(with: NSRange(location: start, length: clampedCaret - start))
        let replace = NSRange(location: start, length: clampedCaret - start)

        // Dot context? Look at the char just before the partial word.
        var dotOwner: String? = nil
        if start > 0, ns.character(at: start - 1) == 0x2E /* '.' */ {
            var oStart = start - 1
            while oStart > 0, isIdentChar(ns.character(at: oStart - 1)) { oStart -= 1 }
            let owner = ns.substring(with: NSRange(location: oStart, length: (start - 1) - oStart))
            if !owner.isEmpty { dotOwner = owner }
        }

        let items: [Completion]
        if let owner = dotOwner {
            items = dotCompletions(owner: owner, text: text, schema: schema)
        } else {
            items = wordCompletions(schema: schema)
        }
        let filtered = rank(items, query: query)
        return (filtered, query, replace)
    }

    // `owner.` — columns of the table `owner` resolves to (direct name or FROM/JOIN alias),
    // or, if owner is a schema, the tables in that schema.
    private static func dotCompletions(owner: String, text: String, schema: SchemaIndex) -> [Completion] {
        // 1) Direct table match (bare or schema-qualified).
        if let cols = schema.columns(forTableToken: owner) {
            return cols.map(columnCompletion)
        }
        // 2) Alias resolution: FROM/JOIN <schema.table> [AS] <owner>.
        if let table = resolveAlias(owner, in: text), let cols = schema.columns(forTableToken: table) {
            return cols.map(columnCompletion)
        }
        // 3) Owner is a schema → its tables.
        let inSchema = schema.tables.filter { $0.schema.lowercased() == owner.lowercased() }
        if !inSchema.isEmpty {
            return inSchema.map { Completion(label: $0.name, kind: $0.kind == "view" || $0.kind == "matview" ? .view : .table, detail: $0.schema) }
        }
        return []
    }

    // Keywords + functions + table names (bare + qualified).
    private static func wordCompletions(schema: SchemaIndex) -> [Completion] {
        var out: [Completion] = []
        out += SQLDialect.keywordList.map { Completion(label: $0.uppercased(), kind: .keyword) }
        out += SQLDialect.functionList.map { Completion(label: $0, kind: .function, detail: "function") }
        for t in schema.tables {
            let kind: CompletionKind = (t.kind == "view" || t.kind == "matview") ? .view : .table
            out.append(Completion(label: t.name, kind: kind, detail: t.schema))
            if t.schema != "public" {
                out.append(Completion(label: "\(t.schema).\(t.name)", kind: kind, detail: "table"))
            }
        }
        return out
    }

    private static func columnCompletion(_ c: SchemaIndex.Col) -> Completion {
        Completion(label: c.name, kind: .column, type: c.type, detail: c.fk ? "fk" : nil, pk: c.pk)
    }

    /// Scan for `FROM/JOIN <ident[.ident]> [AS] <alias>` to map an alias to a table.
    private static func resolveAlias(_ alias: String, in text: String) -> String? {
        let pattern = "(?i)(?:from|join)\\s+([A-Za-z_][A-Za-z0-9_\\.]*)\\s+(?:as\\s+)?([A-Za-z_][A-Za-z0-9_]*)"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let table = ns.substring(with: m.range(at: 1))
            let a = ns.substring(with: m.range(at: 2))
            if a.lowercased() == alias.lowercased() { return table }
        }
        return nil
    }

    private static func rank(_ items: [Completion], query: String) -> [Completion] {
        guard !query.isEmpty else {
            // No prefix (e.g. right after a dot): show everything the context produced.
            return Array(items.prefix(60))
        }
        let q = query.lowercased()
        let starts = items.filter { $0.label.lowercased().hasPrefix(q) }
        let contains = items.filter { !$0.label.lowercased().hasPrefix(q) && $0.label.lowercased().contains(q) }
        let ranked = (starts.sorted { $0.label.count < $1.label.count } + contains)
        return Array(ranked.prefix(60))
    }

    private static func isIdentChar(_ c: unichar) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x5F // A-Z a-z 0-9 _
    }
}

// MARK: - Popover state (observed by the SwiftUI card)

final class CompletionState: ObservableObject {
    @Published var items: [Completion] = []
    @Published var active: Int = 0
    @Published var query: String = ""
}

// MARK: - Completion controller (borderless floating panel hosting the DS card)

@MainActor
final class CompletionController {
    private var panel: NSPanel?
    let state = CompletionState()
    var onSelect: ((Completion) -> Void)?
    private(set) var isVisible = false

    private let cardWidth: CGFloat = 320
    private let rowH: CGFloat = 28
    private let footerH: CGFloat = 26
    private let maxRows = 8

    /// Show/update the popover for `items`, anchored with its top-left near a caret
    /// rect given in screen coordinates. Hides automatically when `items` is empty.
    func present(items: [Completion], query: String, caretRectOnScreen rect: NSRect, isDark: Bool) {
        guard !items.isEmpty else { hide(); return }
        state.items = items
        state.query = query
        if state.active >= items.count { state.active = 0 }

        let rows = CGFloat(min(items.count, maxRows))
        let height = rows * rowH + 8 + footerH
        let size = NSSize(width: cardWidth, height: height)

        let panel = ensurePanel(isDark: isDark)
        // Prefer to sit just below the caret; flip above if it would clip the screen.
        var origin = NSPoint(x: rect.minX, y: rect.minY - height - 4)
        if let screen = NSScreen.main, origin.y < screen.visibleFrame.minY {
            origin.y = rect.maxY + 4
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if !isVisible { panel.orderFront(nil); isVisible = true }
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
        state.active = 0
    }

    func moveSelection(_ delta: Int) {
        guard !state.items.isEmpty else { return }
        let n = state.items.count
        state.active = (state.active + delta % n + n) % n
    }

    func acceptCurrent() {
        guard isVisible, state.items.indices.contains(state.active) else { return }
        let item = state.items[state.active]
        hide()
        onSelect?(item)
    }

    private func ensurePanel(isDark: Bool) -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: cardWidth, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.hasShadow = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hidesOnDeactivate = false
        let host = NSHostingView(rootView: CompletionCard(state: state, isDark: isDark,
                                                          onPick: { [weak self] in self?.acceptCurrent() },
                                                          onHover: { [weak self] i in self?.state.active = i }))
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        panel = p
        return p
    }
}

// MARK: - The DS SqlCompletions card (SwiftUI)

private struct CompletionCard: View {
    @ObservedObject var state: CompletionState
    let isDark: Bool
    let onPick: () -> Void
    let onHover: (Int) -> Void

    private var pal: Palette { Palette(isDark: isDark) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(state.items.enumerated()), id: \.offset) { idx, item in
                            row(item, active: idx == state.active)
                                .id(idx)
                                .contentShape(Rectangle())
                                .onHover { if $0 { onHover(idx) } }
                                .onTapGesture { onHover(idx); onPick() }
                        }
                    }
                    .padding(4)
                }
                .onChange(of: state.active) { a in withAnimation(.linear(duration: 0.05)) { proxy.scrollTo(a) } }
            }
            footer
        }
        .background(pal.surfaceCard)
        .overlay(RoundedRectangle(cornerRadius: Metrics.radiusMD, style: .continuous).strokeBorder(pal.borderSubtle, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusMD, style: .continuous))
        .shadow(color: .black.opacity(isDark ? 0.6 : 0.20), radius: 20, y: 12)
    }

    private func row(_ item: Completion, active: Bool) -> some View {
        HStack(spacing: 8) {
            glyph(item)
            emphasizedLabel(item.label)
                .font(.mono(12.5))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let type = item.type {
                Text(type)
                    .font(.mono(11))
                    .foregroundColor(pal.typeColors(TypeFamily.from(type)).fg)
            } else if let detail = item.detail {
                Text(detail).font(.ui(11)).foregroundColor(pal.textFaint)
            }
            if item.pk {
                Image(systemName: "key.fill").font(.system(size: 9)).foregroundColor(pal.amber400)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusSM, style: .continuous)
                .fill(active ? pal.accentSubtle : .clear)
        )
        .overlay(alignment: .leading) {
            if active {
                Rectangle().fill(pal.accent).frame(width: 2)
                    .clipShape(RoundedRectangle(cornerRadius: 1))
            }
        }
    }

    private func glyph(_ item: Completion) -> some View {
        let c = glyphColor(item)
        return Text(glyphLetter(item.kind))
            .font(.mono(10.5, weight: .bold))
            .foregroundColor(c)
            .frame(width: 17, height: 17)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(c.opacity(0.15)))
    }

    private func emphasizedLabel(_ label: String) -> Text {
        let q = state.query
        guard !q.isEmpty, label.lowercased().hasPrefix(q.lowercased()) else {
            return Text(label).foregroundColor(active(label) ? pal.textPrimary : pal.textSecondary)
        }
        let hit = String(label.prefix(q.count))
        let rest = String(label.dropFirst(q.count))
        return Text(hit).foregroundColor(pal.accentHover).fontWeight(.semibold)
            + Text(rest).foregroundColor(pal.textPrimary)
    }

    // Best-effort "is this row active" for label color (only matters visually when active).
    private func active(_ label: String) -> Bool {
        state.items.indices.contains(state.active) && state.items[state.active].label == label
    }

    private func glyphLetter(_ kind: CompletionKind) -> String {
        switch kind {
        case .keyword: return "K"
        case .function: return "ƒ"
        case .table: return "t"
        case .view: return "v"
        case .schema: return "s"
        case .column: return "c"
        case .snippet: return "{}"
        }
    }

    private func glyphColor(_ item: Completion) -> Color {
        if item.kind == .column, let type = item.type { return pal.typeColors(TypeFamily.from(type)).fg }
        switch item.kind {
        case .keyword: return pal.syntax.keyword
        case .function: return pal.syntax.function
        case .table: return pal.syntax.table
        case .view: return pal.typeColors(.temporal).fg
        case .schema: return pal.textMuted
        case .column: return pal.azure500
        case .snippet: return pal.syntax.number
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            hint("↑↓", "Navigate")
            hint("⏎", "Select")
            hint("esc", "Dismiss")
            Spacer()
            Text("\(state.active + 1)/\(state.items.count)").font(.mono(11)).foregroundColor(pal.textFaint)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(pal.surfacePanel)
        .overlay(Divider().overlay(pal.borderSubtle), alignment: .top)
    }

    private func hint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.mono(10.5))
                .foregroundColor(pal.textSecondary)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: Metrics.radiusXS).fill(pal.surfaceRaised))
                .overlay(RoundedRectangle(cornerRadius: Metrics.radiusXS).strokeBorder(pal.borderDefault, lineWidth: 1))
            Text(label).font(.ui(11)).foregroundColor(pal.textFaint)
        }
    }
}
