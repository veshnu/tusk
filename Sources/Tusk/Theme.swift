import SwiftUI

// MARK: - Hex color helper

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

// MARK: - Radius / metrics tokens (theme-independent)

enum Metrics {
    static let radiusXS: CGFloat = 4
    static let radiusSM: CGFloat = 6      // default control radius
    static let radiusMD: CGFloat = 10     // cards, menus, popovers
    static let radiusLG: CGFloat = 14     // dialogs, large surfaces

    static let controlHeightSM: CGFloat = 26
    static let controlHeightMD: CGFloat = 30
    static let controlHeightLG: CGFloat = 38
    static let rowHeight: CGFloat = 32
    static let toolbarHeight: CGFloat = 46
    static let tabbarHeight: CGFloat = 38
}

// MARK: - Datatype badge families

enum TypeFamily {
    case numeric, text, temporal, bool, uuid, json, other

    /// Map a Postgres type name to a color family (mirrors the DS TypeBadge).
    static func from(_ pgType: String) -> TypeFamily {
        let t = pgType.lowercased()
        if t.contains("json") { return .json }
        if t.contains("uuid") { return .uuid }
        if t.contains("bool") { return .bool }
        if t.contains("timestamp") || t.contains("date") || t.contains("time") || t.contains("interval") { return .temporal }
        if t.contains("int") || t.contains("numeric") || t.contains("decimal") || t.contains("real")
            || t.contains("double") || t.contains("float") || t.contains("serial") || t.contains("money") { return .numeric }
        if t.contains("text") || t.contains("char") || t.contains("name") || t.contains("citext") { return .text }
        return .other
    }
}

// MARK: - Palette (theme-aware, mirrors tokens/semantic.css)

struct Palette {
    let isDark: Bool

    // Surfaces
    var surfaceApp: Color { isDark ? Color(hex: 0x000000) : Color(hex: 0xF5F5F7) }
    var surfacePanel: Color { isDark ? Color(hex: 0x1C1C1E) : Color(hex: 0xFBFBFD) }
    var surfaceRaised: Color { isDark ? Color(hex: 0x2C2C2E) : Color(hex: 0xFFFFFF) }
    var surfaceCard: Color { isDark ? Color(hex: 0x2C2C2E) : Color(hex: 0xFFFFFF) }
    var surfaceInset: Color { isDark ? Color(hex: 0x1C1C1E) : Color(hex: 0xFFFFFF) }
    var surfaceHover: Color { isDark ? Color(hex: 0xFFFFFF, alpha: 0.06) : Color(hex: 0x000000, alpha: 0.04) }
    var surfaceActive: Color { isDark ? Color(hex: 0xFFFFFF, alpha: 0.10) : Color(hex: 0x000000, alpha: 0.07) }
    var surfaceSelected: Color { isDark ? Color(hex: 0x0A84FF, alpha: 0.22) : Color(hex: 0x007AFF, alpha: 0.10) }

    // Borders
    var borderSubtle: Color { isDark ? Color(hex: 0x1C1C1E) : Color(hex: 0xE5E5EA) }
    var borderDefault: Color { isDark ? Color(hex: 0x3A3A3C) : Color(hex: 0xDDDDE2) }
    var borderStrong: Color { isDark ? Color(hex: 0x48484A) : Color(hex: 0xD2D2D7) }

    // Text
    var textPrimary: Color { isDark ? Color(hex: 0xF5F5F7) : Color(hex: 0x1D1D1F) }
    var textSecondary: Color { isDark ? Color(hex: 0x98989D) : Color(hex: 0x6E6E73) }
    var textMuted: Color { Color(hex: 0x8E8E93) }
    var textFaint: Color { isDark ? Color(hex: 0x636366) : Color(hex: 0xC7C7CC) }
    var textOnAccent: Color { .white }

    // Accent (Apple system blue)
    var accent: Color { isDark ? Color(hex: 0x0A84FF) : Color(hex: 0x007AFF) }
    var accentHover: Color { isDark ? Color(hex: 0x409CFF) : Color(hex: 0x1A88FF) }
    var accentPress: Color { isDark ? Color(hex: 0x007AFF) : Color(hex: 0x0062CC) }
    var azure400: Color { Color(hex: 0x0A84FF) }
    var azure500: Color { Color(hex: 0x007AFF) }
    var azure600: Color { Color(hex: 0x0062CC) }
    var amber400: Color { Color(hex: 0xFF9F0A) }
    var amber500: Color { Color(hex: 0xFF9500) }

    /// Accent wash used behind active/selected rows in menus, completions, cells.
    var accentSubtle: Color { isDark ? Color(hex: 0x0A84FF, alpha: 0.18) : Color(hex: 0x007AFF, alpha: 0.10) }

    // Semantic status
    var success: Color { isDark ? Color(hex: 0x30D158) : Color(hex: 0x248A3D) }
    var danger: Color { isDark ? Color(hex: 0xFF453A) : Color(hex: 0xFF3B30) }
    var warning: Color { isDark ? Color(hex: 0xFF9F0A) : Color(hex: 0xE07E00) }

    // Connection status dots
    var statusConnected: Color { isDark ? Color(hex: 0x30D158) : Color(hex: 0x34C759) }
    var statusConnecting: Color { isDark ? Color(hex: 0xFF9F0A) : Color(hex: 0xFF9500) }
    var statusDisconnected: Color { isDark ? Color(hex: 0x8E8E93) : Color(hex: 0xC7C7CC) }
    var statusError: Color { isDark ? Color(hex: 0xFF453A) : Color(hex: 0xFF3B30) }

    // Datatype badge colors (bg / fg)
    func typeColors(_ family: TypeFamily) -> (bg: Color, fg: Color) {
        switch family {
        case .numeric:
            return isDark ? (Color(hex: 0x0A84FF, alpha: 0.20), Color(hex: 0x6BAAFF))
                          : (Color(hex: 0x007AFF, alpha: 0.12), Color(hex: 0x0062CC))
        case .text:
            return isDark ? (Color(hex: 0x30D158, alpha: 0.18), Color(hex: 0x6BE08D))
                          : (Color(hex: 0x34C759, alpha: 0.14), Color(hex: 0x248A3D))
        case .temporal:
            return isDark ? (Color(hex: 0xFF9F0A, alpha: 0.20), Color(hex: 0xFFC46B))
                          : (Color(hex: 0xFF9500, alpha: 0.16), Color(hex: 0xB36400))
        case .bool:
            return isDark ? (Color(hex: 0xBF5AF2, alpha: 0.22), Color(hex: 0xD9A2FF))
                          : (Color(hex: 0xAF52DE, alpha: 0.14), Color(hex: 0x8944AB))
        case .uuid:
            return isDark ? (Color(hex: 0x64D2FF, alpha: 0.18), Color(hex: 0x8CE0F0))
                          : (Color(hex: 0x30B0C7, alpha: 0.16), Color(hex: 0x278596))
        case .json:
            return isDark ? (Color(hex: 0xFF375F, alpha: 0.18), Color(hex: 0xFF9FB6))
                          : (Color(hex: 0xFF2D55, alpha: 0.12), Color(hex: 0xFF2D55))
        case .other:
            return isDark ? (Color(hex: 0xFFFFFF, alpha: 0.08), Color(hex: 0x98989D))
                          : (Color(hex: 0x000000, alpha: 0.05), Color(hex: 0x6E6E73))
        }
    }

    // SQL syntax highlighting (Xcode "Default" flavor, per DS tokens/semantic.css)
    struct Syntax {
        let keyword, function, string, number, boolean, comment, table, identifier, oper, punct: Color
    }
    var syntax: Syntax {
        isDark
        ? Syntax(keyword: Color(hex: 0xFF7AB2), function: Color(hex: 0x67B7A4), string: Color(hex: 0xFF8170),
                 number: Color(hex: 0xD9C97C), boolean: Color(hex: 0xDABAFF), comment: Color(hex: 0x7F8C98),
                 table: Color(hex: 0xD9A2FF), identifier: textPrimary, oper: textSecondary, punct: textMuted)
        : Syntax(keyword: Color(hex: 0x9B2393), function: Color(hex: 0x3E8087), string: Color(hex: 0xC41A16),
                 number: Color(hex: 0x1C00CF), boolean: Color(hex: 0x5C2699), comment: Color(hex: 0x5D6C79),
                 table: Color(hex: 0x5C2699), identifier: textPrimary, oper: textSecondary, punct: textMuted)
    }

    // Env badge color (production/staging/dev/local)
    func envColor(_ env: String) -> Color {
        switch env.lowercased() {
        case "production", "prod": return danger
        case "staging", "stg": return warning
        case "dev", "development": return success
        default: return textMuted
        }
    }
}

// MARK: - Environment plumbing

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette(isDark: false)
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

// MARK: - Font helpers

extension Font {
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}
