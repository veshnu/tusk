import SwiftUI

struct NewConnectionModal: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.palette) var pal
    @Environment(\.dismiss) var dismiss

    let existing: Connection?
    let onSave: (Connection) -> Void
    let onConnect: (Connection) -> Void

    @State private var form: Connection
    @State private var test: TestState = .idle

    enum TestState: Equatable {
        case idle, testing, ok(String), error(String)
    }

    private let sslModes = ["disable", "allow", "prefer", "require", "verify-full"]

    init(existing: Connection?,
         onSave: @escaping (Connection) -> Void,
         onConnect: @escaping (Connection) -> Void) {
        self.existing = existing
        self.onSave = onSave
        self.onConnect = onConnect
        _form = State(initialValue: existing ?? Connection.blank())
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            body_
            footer
        }
        .frame(width: 520)
        .background(pal.surfaceCard)
        .environment(\.palette, pal)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LinearGradient(colors: [pal.azure400, pal.azure600], startPoint: .top, endPoint: .bottom))
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: "bolt.horizontal.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                )
                .shadow(color: pal.accent.opacity(0.30), radius: 6, x: 0, y: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(existing == nil ? "New connection" : "Edit connection")
                    .font(.ui(16, weight: .semibold))
                    .foregroundColor(pal.textPrimary)
                Text("Connect Tusk to a PostgreSQL server.")
                    .font(.ui(12))
                    .foregroundColor(pal.textSecondary)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(pal.textMuted)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: Body

    private var body_: some View {
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
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            TuskButton(title: isTesting ? "Testing" : "Test connection",
                       variant: .secondary, size: .small,
                       loading: isTesting) {
                runTest()
            }
            testResult
            Spacer()
            TuskButton(title: "Cancel", variant: .ghost) { dismiss() }
            TuskButton(title: "Connect", icon: "bolt.horizontal.circle", variant: .primary) {
                let conn = normalizedForm()
                onConnect(conn)
                dismiss()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(pal.surfacePanel)
        .overlay(Divider().overlay(pal.borderSubtle), alignment: .top)
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
                Text(msg).font(.mono(11.5)).foregroundColor(pal.danger).lineLimit(1)
            }
        }
    }

    // MARK: Logic

    private var isTesting: Bool { test == .testing }
    private var isErrorState: Bool { if case .error = test { return true }; return false }

    private func normalizedForm() -> Connection {
        var c = form
        c.name = c.name.trimmingCharacters(in: .whitespaces)
        if c.name.isEmpty { c.name = c.database }
        c.host = c.host.trimmingCharacters(in: .whitespaces)
        c.port = c.port.trimmingCharacters(in: .whitespaces)
        return c
    }

    private func runTest() {
        guard !isTesting else { return }
        test = .testing
        let cfg = normalizedForm()
        Task {
            do {
                let r = try await model.db.test(cfg)
                test = .ok("Connected · \(Int(r.latencyMs.rounded())) ms · \(r.serverVersion)")
            } catch {
                test = .error(error.localizedDescription.replacingOccurrences(of: "\n", with: " "))
            }
        }
    }
}
