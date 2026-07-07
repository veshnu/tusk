import SwiftUI
import AppKit
import SwiftTerm

// MARK: - Session controller

/// Owns the long-lived embedded terminal. Kept outside SwiftUI so hiding/showing
/// the panel (or toggling from the title bar) doesn't kill the running session.
@MainActor final class TerminalController {
    private var term: LocalProcessTerminalView?

    /// The terminal view, spawning `claude` in a login shell on first use.
    func start(isDark: Bool) -> LocalProcessTerminalView {
        if let term { applyTheme(term, isDark: isDark); return term }
        let t = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        applyTheme(t, isDark: isDark)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // Interactive *and* login shell: GUI apps start with a bare PATH, and many
        // setups add tools (e.g. ~/.local/bin) in .zshrc, which only interactive
        // shells source. Then exec the Claude Code CLI so it owns the pty directly.
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        t.startProcess(executable: shell,
                       args: ["-i", "-l", "-c", "exec claude"],
                       environment: env.map { "\($0)=\($1)" },
                       currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
        term = t
        return t
    }

    func applyTheme(isDark: Bool) {
        if let term { applyTheme(term, isDark: isDark) }
    }

    private func applyTheme(_ t: LocalProcessTerminalView, isDark: Bool) {
        if isDark {
            t.nativeBackgroundColor = NSColor(srgbRed: 0x1C/255.0, green: 0x1C/255.0, blue: 0x1E/255.0, alpha: 1)
            t.nativeForegroundColor = NSColor(srgbRed: 0xF5/255.0, green: 0xF5/255.0, blue: 0xF7/255.0, alpha: 1)
        } else {
            t.nativeBackgroundColor = .white
            t.nativeForegroundColor = NSColor(srgbRed: 0x1D/255.0, green: 0x1D/255.0, blue: 0x1F/255.0, alpha: 1)
        }
    }
}

// MARK: - SwiftUI wrapper

/// Hosts the persistent terminal view inside a lightweight container so SwiftUI
/// can add/remove it without tearing down the process.
private struct ClaudeTerminalContainer: NSViewRepresentable {
    let controller: TerminalController
    let isDark: Bool

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        let term = controller.start(isDark: isDark)
        term.removeFromSuperview()
        term.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(term)
        NSLayoutConstraint.activate([
            term.topAnchor.constraint(equalTo: host.topAnchor),
            term.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            term.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            term.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        DispatchQueue.main.async { host.window?.makeFirstResponder(term) }
        return host
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        controller.applyTheme(isDark: isDark)
    }
}

// MARK: - Panel

/// The bottom-docked Claude Code terminal panel.
struct ClaudeTerminalPanel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.palette) var pal

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(pal.borderSubtle)
            ClaudeTerminalContainer(controller: model.terminal, isDark: model.isDark)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(pal.surfaceRaised)
        .overlay(Divider().overlay(pal.borderDefault), alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "asterisk").font(.system(size: 11, weight: .bold)).foregroundColor(pal.accent)
            Text("Claude").font(.ui(12, weight: .semibold)).foregroundColor(pal.textPrimary)
            Spacer()
            Button { model.showTerminal = false } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .foregroundColor(pal.textMuted)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: Metrics.tabbarHeight)
        .background(pal.surfacePanel)
    }
}

// MARK: - Vertical resize bar (drag to grow the panel upward)

struct TerminalResizeBar: View {
    @Environment(\.palette) var pal
    @Binding var height: Double
    let range: ClosedRange<Double>

    @State private var startHeight: Double?
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
                    .onChanged { value in
                        let base = startHeight ?? height
                        if startHeight == nil { startHeight = base }
                        // Bar sits on the panel's top edge: dragging up grows it.
                        let proposed = base - Double(value.translation.height)
                        height = min(max(proposed, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in startHeight = nil }
            )
    }
}
