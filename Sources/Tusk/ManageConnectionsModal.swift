import SwiftUI
import TuskCore

/// The unified master-detail "Manage connections" modal: a list of saved
/// connections on the left (add/remove), an editor form on the right, with
/// Test + Connect/Disconnect + Save. Replaces the old full-screen connect screen
/// and the standalone new-connection sheet — every connection is created, edited,
/// tested, and opened from here.
struct ManageConnectionsModal: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: ConnectionStore
    @Environment(\.palette) var pal
    @Environment(\.dismiss) var dismiss

    /// Which connection to preselect when opening (nil → first), and whether to
    /// immediately create a fresh one.
    let preselect: String?
    var addNew: Bool = false

    @State private var editingId: String?
    @State private var form: Connection = .blank()
    @State private var test: TestState = .idle
    @State private var didInit = false

    enum TestState: Equatable { case idle, testing, ok(String), error(String) }

    private let sslModes = ["disable", "allow", "prefer", "require", "verify-full"]
    private let envs = ["local", "dev", "staging", "production"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(pal.borderSubtle)
            HStack(spacing: 0) {
                connectionList
                Divider().overlay(pal.borderSubtle)
                editor
            }
        }
        .frame(width: 760, height: 540)
        .background(pal.surfaceCard)
        .environment(\.palette, pal)
        .onAppear { initialize() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LinearGradient(colors: [pal.azure400, pal.azure600], startPoint: .top, endPoint: .bottom))
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: "cylinder.split.1x2.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                )
                .shadow(color: pal.accent.opacity(0.30), radius: 6, x: 0, y: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text("Manage connections")
                    .font(.ui(15, weight: .semibold))
                    .foregroundColor(pal.textPrimary)
                Text("Configure the PostgreSQL servers Tusk can open.")
                    .font(.ui(12))
                    .foregroundColor(pal.textSecondary)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(pal.textMuted)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: Connection list

    private var connectionList: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(store.connections) { c in
                        listRow(c)
                    }
                }
                .padding(8)
            }
            Divider().overlay(pal.borderSubtle)
            HStack(spacing: 4) {
                Button { addConnection() } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .medium)).foregroundColor(pal.textMuted)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Add connection")
                Button { removeConnection() } label: {
                    Image(systemName: "minus").font(.system(size: 12, weight: .medium)).foregroundColor(pal.textMuted)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Remove connection")
                .disabled(editingId == nil)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 36)
        }
        .frame(width: 236)
        .background(pal.surfacePanel)
    }

    private func listRow(_ c: Connection) -> some View {
        let selected = editingId == c.id
        return HStack(spacing: 10) {
            StatusDot(status: model.status(for: c.id), size: 9)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(c.name.isEmpty ? "Untitled" : c.name)
                        .font(.ui(13, weight: .medium))
                        .foregroundColor(pal.textPrimary)
                        .lineLimit(1)
                    Badge(text: c.env, color: pal.envColor(c.env))
                }
                Text("\(c.hostPort) · \(c.database)")
                    .font(.mono(11))
                    .foregroundColor(pal.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusMD, style: .continuous)
                .fill(selected ? pal.surfaceSelected : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusMD, style: .continuous)
                .strokeBorder(selected ? pal.accent : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { selectConnection(c.id) }
    }

    // MARK: Editor

    @ViewBuilder private var editor: some View {
        if editingId == nil {
            VStack(spacing: 8) {
                Image(systemName: "cylinder.split.1x2").font(.system(size: 24)).foregroundColor(pal.textFaint)
                Text("Select a connection, or add a new one.")
                    .font(.ui(13)).foregroundColor(pal.textMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(pal.surfaceCard)
        } else {
            VStack(spacing: 0) {
                editorHeader
                Divider().overlay(pal.borderSubtle)
                editorForm
                Divider().overlay(pal.borderSubtle)
                editorFooter
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var editorHeader: some View {
        let status = editingId.map { model.status(for: $0) } ?? "disconnected"
        let connected = status == "connected"
        return HStack(spacing: 10) {
            Text(form.name.isEmpty ? "Untitled" : form.name)
                .font(.ui(14, weight: .semibold))
                .foregroundColor(pal.textPrimary)
                .lineLimit(1)
            Badge(text: form.env, color: pal.envColor(form.env))
            Spacer()
            StatusDot(status: status, size: 8)
            Text(connected ? "Connected" : status.capitalized)
                .font(.mono(11)).foregroundColor(pal.textMuted)
            TuskButton(title: connected ? "Disconnect" : "Connect",
                       variant: .secondary, size: .small,
                       loading: status == "connecting") {
                if connected { model.disconnect(editingId!) }
                else { connect() }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var editorForm: some View {
        ScrollView {
            VStack(spacing: 13) {
                LabeledField(label: "Connection name") {
                    TuskTextField(placeholder: "My database", text: $form.name, mono: false)
                        .onChange(of: form.name) { _ in test = .idle }
                }
                HStack(spacing: 12) {
                    LabeledField(label: "Host") {
                        TuskTextField(placeholder: "localhost", text: $form.host, leadingIcon: "server.rack")
                            .onChange(of: form.host) { _ in test = .idle }
                    }
                    LabeledField(label: "Port") {
                        TuskTextField(placeholder: "5432", text: $form.port, invalid: isErrorState)
                            .onChange(of: form.port) { _ in test = .idle }
                    }
                    .frame(width: 96)
                }
                LabeledField(label: "Database") {
                    TuskTextField(placeholder: "postgres", text: $form.database, leadingIcon: "cylinder")
                        .onChange(of: form.database) { _ in test = .idle }
                }
                HStack(spacing: 12) {
                    LabeledField(label: "User") {
                        TuskTextField(placeholder: "postgres", text: $form.user, leadingIcon: "person")
                            .onChange(of: form.user) { _ in test = .idle }
                    }
                    LabeledField(label: "Password") {
                        TuskTextField(placeholder: "••••••••", text: $form.password, leadingIcon: "lock", secure: true)
                            .onChange(of: form.password) { _ in test = .idle }
                    }
                }
                HStack(alignment: .bottom, spacing: 12) {
                    LabeledField(label: "SSL mode") {
                        TuskPicker(selection: $form.sslMode, options: sslModes)
                            .onChange(of: form.sslMode) { _ in test = .idle }
                    }
                    .frame(width: 150)
                    LabeledField(label: "Environment") {
                        TuskPicker(selection: $form.env, options: envs)
                    }
                    .frame(width: 140)
                    Toggle(isOn: $form.savePassword) {
                        Text("Save password in keychain")
                            .font(.ui(13))
                            .foregroundColor(pal.textSecondary)
                    }
                    .toggleStyle(.checkbox)
                    .padding(.bottom, 7)
                    Spacer()
                }
            }
            .padding(18)
        }
    }

    private var editorFooter: some View {
        HStack(spacing: 10) {
            TuskButton(title: isTesting ? "Testing" : "Test connection",
                       variant: .secondary, size: .small,
                       loading: isTesting) {
                runTest()
            }
            testResult
            Spacer()
            TuskButton(title: "Cancel", variant: .ghost, size: .small) { dismiss() }
            TuskButton(title: "Save changes", variant: .primary, size: .small) { saveForm() }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(pal.surfacePanel)
    }

    @ViewBuilder private var testResult: some View {
        switch test {
        case .idle, .testing:
            EmptyView()
        case .ok(let msg):
            HStack(spacing: 6) {
                StatusDot(status: "connected", size: 7)
                Text(msg).font(.mono(11.5)).foregroundColor(pal.success).lineLimit(1)
            }
        case .error(let msg):
            HStack(spacing: 6) {
                StatusDot(status: "error", size: 7)
                Text(msg).font(.mono(11.5)).foregroundColor(pal.danger).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    // MARK: Logic

    private var isTesting: Bool { test == .testing }
    private var isErrorState: Bool { if case .error = test { return true }; return false }

    private func initialize() {
        guard !didInit else { return }
        didInit = true
        if addNew {
            addConnection()
        } else {
            selectConnection(preselect ?? store.connections.first?.id)
        }
    }

    private func selectConnection(_ id: String?) {
        editingId = id
        test = .idle
        if let id, let c = store.connections.first(where: { $0.id == id }) {
            form = store.withPassword(c)
        } else {
            form = .blank()
        }
    }

    private func addConnection() {
        var c = Connection.blank()
        c.name = "New connection"
        store.upsert(c)
        editingId = c.id
        form = c
        test = .idle
    }

    private func removeConnection() {
        guard let id = editingId, let c = store.connections.first(where: { $0.id == id }) else { return }
        if model.session(id) != nil { model.disconnect(id) }
        store.remove(c)
        selectConnection(store.connections.first?.id)
    }

    private func normalizedForm() -> Connection {
        var c = form
        c.name = c.name.trimmingCharacters(in: .whitespaces)
        if c.name.isEmpty { c.name = c.database }
        c.host = c.host.trimmingCharacters(in: .whitespaces)
        c.port = c.port.trimmingCharacters(in: .whitespaces)
        return c
    }

    private func saveForm() {
        let c = normalizedForm()
        store.upsert(c)
        form = c
    }

    private func connect() {
        let c = normalizedForm()
        store.upsert(c)
        model.connect(c)   // `c` still carries the typed password
    }

    private func runTest() {
        guard !isTesting else { return }
        test = .testing
        let cfg = normalizedForm()
        Task {
            do {
                let r = try await model.testConnection(cfg)
                test = .ok("Connected · \(Int(r.latencyMs.rounded())) ms · \(r.serverVersion)")
            } catch {
                test = .error(error.localizedDescription.replacingOccurrences(of: "\n", with: " "))
            }
        }
    }
}
