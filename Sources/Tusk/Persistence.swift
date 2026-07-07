import Foundation
import Security
import TuskCore

// MARK: - Keychain (password storage)

enum Keychain {
    private static let service = "com.veshnu.Tusk"

    static func save(_ password: String, for id: String) {
        let account = id
        let data = Data(password.utf8)
        // Delete any existing item first.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !password.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(for id: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for id: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Connection store

@MainActor
final class ConnectionStore: ObservableObject {
    @Published private(set) var connections: [Connection] = []

    private let defaultsKey = "tusk.connections.v1"

    init() {
        load()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([Connection].self, from: data) else {
            return
        }
        connections = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(connections) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    /// Add or update a connection. Password handling honors `savePassword`.
    func upsert(_ conn: Connection) {
        var toStore = conn
        if conn.savePassword {
            Keychain.save(conn.password, for: conn.id)
        } else {
            Keychain.delete(for: conn.id)
        }
        // Never persist the password to UserDefaults.
        toStore.password = ""
        if let idx = connections.firstIndex(where: { $0.id == conn.id }) {
            connections[idx] = toStore
        } else {
            connections.append(toStore)
        }
        persist()
    }

    func remove(_ conn: Connection) {
        Keychain.delete(for: conn.id)
        connections.removeAll { $0.id == conn.id }
        persist()
    }

    /// Returns the connection with its saved password (from Keychain) filled in.
    func withPassword(_ conn: Connection) -> Connection {
        var c = conn
        if conn.savePassword, let pw = Keychain.load(for: conn.id) {
            c.password = pw
        }
        return c
    }
}
