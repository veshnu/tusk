import SwiftUI

// MARK: - Status dot

struct StatusDot: View {
    @Environment(\.palette) private var pal
    let status: String
    var size: CGFloat = 8

    private var color: Color {
        switch status {
        case "connected": return pal.statusConnected
        case "connecting": return pal.statusConnecting
        case "error": return pal.statusError
        default: return pal.statusDisconnected
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.5), radius: size * 0.4)
    }
}

// MARK: - Badge

struct Badge: View {
    @Environment(\.palette) private var pal
    let text: String
    var color: Color? = nil
    var mono: Bool = false

    var body: some View {
        let c = color ?? pal.textMuted
        Text(text)
            .font(mono ? .mono(10.5, weight: .medium) : .ui(10.5, weight: .semibold))
            .foregroundColor(c)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: Metrics.radiusXS, style: .continuous)
                    .fill(c.opacity(0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radiusXS, style: .continuous)
                    .strokeBorder(c.opacity(0.20), lineWidth: 0.5)
            )
    }
}

// MARK: - Type badge (datatype pill)

struct TypeBadge: View {
    @Environment(\.palette) private var pal
    let type: String

    var body: some View {
        let colors = pal.typeColors(TypeFamily.from(type))
        Text(type)
            .font(.mono(10.5, weight: .medium))
            .foregroundColor(colors.fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: Metrics.radiusXS, style: .continuous)
                    .fill(colors.bg)
            )
            .fixedSize()
    }
}

// MARK: - Buttons

enum TuskButtonVariant { case primary, secondary, ghost, danger }

struct TuskButtonStyle: ButtonStyle {
    @Environment(\.palette) private var pal
    @Environment(\.isEnabled) private var isEnabled
    var variant: TuskButtonVariant = .primary
    var size: ButtonSize = .medium

    enum ButtonSize { case small, medium
        var height: CGFloat { self == .small ? 26 : 30 }
        var hpad: CGFloat { self == .small ? 10 : 13 }
        var font: CGFloat { self == .small ? 12 : 13 }
    }

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(.ui(size.font, weight: .medium))
            .frame(height: size.height)
            .padding(.horizontal, size.hpad)
            .foregroundColor(fg(pressed))
            .background(bg(pressed))
            .overlay(border)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusSM, style: .continuous))
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
    }

    private func fg(_ pressed: Bool) -> Color {
        switch variant {
        case .primary, .danger: return .white
        case .secondary: return pal.textPrimary
        case .ghost: return pal.textSecondary
        }
    }

    @ViewBuilder private func bg(_ pressed: Bool) -> some View {
        switch variant {
        case .primary:
            LinearGradient(colors: [pal.accentHover, pal.accent],
                           startPoint: .top, endPoint: .bottom)
                .brightness(pressed ? -0.06 : 0)
        case .danger:
            pal.danger.brightness(pressed ? -0.06 : 0)
        case .secondary:
            pal.surfaceCard.brightness(pressed ? (pal.isDark ? 0.04 : -0.03) : 0)
        case .ghost:
            (pressed ? pal.surfaceActive : Color.clear)
        }
    }

    @ViewBuilder private var border: some View {
        switch variant {
        case .primary, .danger:
            RoundedRectangle(cornerRadius: Metrics.radiusSM, style: .continuous)
                .strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5)
        case .secondary:
            RoundedRectangle(cornerRadius: Metrics.radiusSM, style: .continuous)
                .strokeBorder(pal.borderDefault, lineWidth: 1)
        case .ghost:
            EmptyView()
        }
    }
}

/// Convenience button with an optional SF Symbol and a loading spinner.
struct TuskButton: View {
    @Environment(\.palette) private var pal
    let title: String
    var icon: String? = nil
    var variant: TuskButtonVariant = .primary
    var size: TuskButtonStyle.ButtonSize = .medium
    var loading: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if loading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 13, height: 13)
                } else if let icon {
                    Image(systemName: icon).font(.system(size: size == .small ? 11 : 12, weight: .semibold))
                }
                Text(title)
            }
        }
        .buttonStyle(TuskButtonStyle(variant: variant, size: size))
        .disabled(loading)
    }
}

// MARK: - Text field

struct TuskTextField: View {
    @Environment(\.palette) private var pal
    var placeholder: String = ""
    @Binding var text: String
    var leadingIcon: String? = nil
    var mono: Bool = true
    var secure: Bool = false
    var invalid: Bool = false

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            if let leadingIcon {
                Image(systemName: leadingIcon)
                    .font(.system(size: 12))
                    .foregroundColor(pal.textFaint)
            }
            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(mono ? .mono(12) : .ui(13))
            .foregroundColor(pal.textPrimary)
            .focused($focused)
            .autocorrectionDisabled(true)
        }
        .padding(.horizontal, 9)
        .frame(height: Metrics.controlHeightMD)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusSM, style: .continuous)
                .fill(pal.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusSM, style: .continuous)
                .strokeBorder(borderColor, lineWidth: focused || invalid ? 1.5 : 1)
        )
        .animation(.easeOut(duration: 0.12), value: focused)
    }

    private var borderColor: Color {
        if invalid { return pal.danger }
        if focused { return pal.accent }
        return pal.borderDefault
    }
}

// MARK: - Labeled field (form row)

struct LabeledField<Content: View>: View {
    @Environment(\.palette) private var pal
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.ui(11, weight: .medium))
                .foregroundColor(pal.textSecondary)
            content
        }
    }
}

// MARK: - Segmented / picker helper for SSL mode

struct TuskPicker: View {
    @Environment(\.palette) private var pal
    @Binding var selection: String
    let options: [String]

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { opt in
                Button(opt) { selection = opt }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selection).font(.ui(13)).foregroundColor(pal.textPrimary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(pal.textFaint)
            }
            .padding(.horizontal, 9)
            .frame(height: Metrics.controlHeightMD)
            .background(
                RoundedRectangle(cornerRadius: Metrics.radiusSM, style: .continuous)
                    .fill(pal.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radiusSM, style: .continuous)
                    .strokeBorder(pal.borderDefault, lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
    }
}
