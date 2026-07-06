import SwiftUI

struct ConnectScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: ConnectionStore
    @Environment(\.palette) var pal

    @State private var selectedID: String?
    @State private var showNew = false
    @State private var editing: Connection?

    private var selected: Connection? {
        store.connections.first { $0.id == selectedID } ?? store.connections.first
    }

    var body: some View {
        ZStack {
            pal.surfaceApp.ignoresSafeArea()
            card
        }
        .sheet(isPresented: $showNew) {
            NewConnectionModal(existing: editing) { conn in
                store.upsert(conn)
                selectedID = conn.id
            } onConnect: { conn in
                store.upsert(conn)
                selectedID = conn.id
                model.connect(store.withPassword(conn))
            }
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            header
            connectionList
            footer
        }
        .frame(width: 460)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusLG, style: .continuous)
                .fill(pal.surfaceCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusLG, style: .continuous)
                .strokeBorder(pal.borderSubtle, lineWidth: 1)
        )
        .shadow(color: .black.opacity(pal.isDark ? 0.6 : 0.14), radius: 34, x: 0, y: 12)
    }

    private var header: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [pal.azure400, pal.azure600], startPoint: .top, endPoint: .bottom))
                .frame(width: 52, height: 52)
                .overlay(
                    Image(systemName: "cylinder.split.1x2.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.white)
                )
                .shadow(color: pal.accent.opacity(0.35), radius: 12, x: 0, y: 6)
                .padding(.bottom, 14)

            Text("Connect to a database")
                .font(.ui(22, weight: .semibold))
                .foregroundColor(pal.textPrimary)
            Text("Choose a Postgres server to open in Tusk.")
                .font(.ui(13))
                .foregroundColor(pal.textSecondary)
                .padding(.top, 5)
        }
        .padding(.top, 28)
        .padding(.bottom, 20)
        .padding(.horizontal, 28)
    }

    @ViewBuilder private var connectionList: some View {
        if store.connections.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 22))
                    .foregroundColor(pal.textFaint)
                Text("No saved connections yet")
                    .font(.ui(13, weight: .medium))
                    .foregroundColor(pal.textSecondary)
                Text("Add a Postgres server to get started.")
                    .font(.ui(12))
                    .foregroundColor(pal.textMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
            .padding(.horizontal, 16)
        } else {
            VStack(spacing: 4) {
                ForEach(store.connections) { c in
                    ConnectionRow(
                        conn: c,
                        selected: (selected?.id == c.id),
                        onTap: { selectedID = c.id },
                        onOpen: {
                            selectedID = c.id
                            model.connect(store.withPassword(c))
                        },
                        onEdit: { editing = c; showNew = true },
                        onDelete: { store.remove(c) }
                    )
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            if let err = model.connectError {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(pal.danger)
                    Text(err)
                        .font(.mono(11.5))
                        .foregroundColor(pal.danger)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            HStack(spacing: 10) {
                TuskButton(title: "New connection", icon: "plus", variant: .ghost) {
                    editing = nil
                    showNew = true
                }
                Spacer()
                TuskButton(title: model.connecting ? "Connecting" : "Connect",
                           icon: "bolt.horizontal.circle",
                           variant: .primary,
                           loading: model.connecting) {
                    if let s = selected {
                        model.connect(store.withPassword(s))
                    }
                }
                .disabled(selected == nil)
            }
            .padding(16)
        }
        .overlay(Divider().overlay(pal.borderSubtle), alignment: .top)
    }
}

// MARK: - Connection row

private struct ConnectionRow: View {
    @Environment(\.palette) var pal
    let conn: Connection
    let selected: Bool
    let onTap: () -> Void
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(status: "disconnected", size: 9)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(conn.name.isEmpty ? "Untitled" : conn.name)
                        .font(.ui(14, weight: .medium))
                        .foregroundColor(pal.textPrimary)
                    Badge(text: conn.env, color: pal.envColor(conn.env))
                }
                Text("\(conn.hostPort) · \(conn.database)")
                    .font(.mono(11))
                    .foregroundColor(pal.textMuted)
            }
            Spacer(minLength: 0)
            if hovering {
                Button(action: onEdit) {
                    Image(systemName: "pencil").font(.system(size: 12)).foregroundColor(pal.textMuted)
                }.buttonStyle(.plain)
                Button(action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 12)).foregroundColor(pal.textMuted)
                }.buttonStyle(.plain)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(pal.textFaint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusMD, style: .continuous)
                .fill(selected ? pal.surfaceSelected : (hovering ? pal.surfaceHover : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusMD, style: .continuous)
                .strokeBorder(selected ? pal.accent : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpen)
        .onTapGesture(perform: onTap)
        .onHover { hovering = $0 }
    }
}
