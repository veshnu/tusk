import SwiftUI
import AppKit
import SwiftTerm

// MARK: - Claude brand mark

/// The Claude sunburst, filled with the Claude clay orange (hsl(14.8 63.1% 59.6%)).
struct ClaudeMark: View {
    var size: CGFloat = 13

    var body: some View {
        Image(nsImage: ClaudeMark.image)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }

    /// Rasterized once from the SVG path (the path spans a 0 0 100 100 viewBox).
    private static let image: NSImage = {
        let path = "m19.6 66.5 19.7-11 .3-1-.3-.5h-1l-3.3-.2-11.2-.3L14 53l-9.5-.5-2.4-.5L0 49l.2-1.5 2-1.3 2.9.2 6.3.5 9.5.6 6.9.4L38 49.1h1.6l.2-.7-.5-.4-.4-.4L29 41l-10.6-7-5.6-4.1-3-2-1.5-2-.6-4.2 2.7-3 3.7.3.9.2 3.7 2.9 8 6.1L37 36l1.5 1.2.6-.4.1-.3-.7-1.1L33 25l-6-10.4-2.7-4.3-.7-2.6c-.3-1-.4-2-.4-3l3-4.2L28 0l4.2.6L33.8 2l2.6 6 4.1 9.3L47 29.9l2 3.8 1 3.4.3 1h.7v-.5l.5-7.2 1-8.7 1-11.2.3-3.2 1.6-3.8 3-2L61 2.6l2 2.9-.3 1.8-1.1 7.7L59 27.1l-1.5 8.2h.9l1-1.1 4.1-5.4 6.9-8.6 3-3.5L77 13l2.3-1.8h4.3l3.1 4.7-1.4 4.9-4.4 5.6-3.7 4.7-5.3 7.1-3.2 5.7.3.4h.7l12-2.6 6.4-1.1 7.6-1.3 3.5 1.6.4 1.6-1.4 3.4-8.2 2-9.6 2-14.3 3.3-.2.1.2.3 6.4.6 2.8.2h6.8l12.6 1 3.3 2 1.9 2.7-.3 2-5.1 2.6-6.8-1.6-16-3.8-5.4-1.3h-.8v.4l4.6 4.5 8.3 7.5L89 80.1l.5 2.4-1.3 2-1.4-.2-9.2-7-3.6-3-8-6.8h-.5v.7l1.8 2.7 9.8 14.7.5 4.5-.7 1.4-2.6 1-2.7-.6-5.8-8-6-9-4.7-8.2-.5.4-2.9 30.2-1.3 1.5-3 1.2-2.5-2-1.4-3 1.4-6.2 1.6-8 1.3-6.4 1.2-7.9.7-2.6v-.2H49L43 72l-9 12.3-7.2 7.6-1.7.7-3-1.5.3-2.8L24 86l10-12.8 6-7.9 4-4.6-.1-.5h-.3L17.2 77.4l-4.7.6-2-2 .2-3 1-1 8-5.5Z"
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 100\"><path fill=\"#D97757\" d=\"" + path + "\"/></svg>"
        let img = NSImage(data: Data(svg.utf8)) ?? NSImage()
        img.size = NSSize(width: 100, height: 100)
        return img
    }()
}

// MARK: - Session controller

/// Owns the long-lived embedded terminal. Kept outside SwiftUI so hiding/showing
/// the panel (or toggling from the title bar) doesn't kill the running session.
@MainActor final class TerminalController {
    private var term: LocalProcessTerminalView?
    private var scrollMonitor: Any?

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
                       currentDirectory: TerminalController.workspaceDirectory())
        term = t
        installScrollMonitor(for: t)
        return t
    }

    /// Keep the panel scrollable even while a full-screen app is running.
    ///
    /// SwiftTerm's native scrollback only covers the normal screen buffer. Claude
    /// Code (like `less` or `vim`) draws into the *alternate* buffer, which has no
    /// scrollback, so the wheel does nothing. Mirroring xterm/iTerm's "alternate
    /// scroll", we translate wheel motion over the terminal into cursor up/down key
    /// presses in that case, and otherwise let SwiftTerm handle native scrollback.
    private func installScrollMonitor(for term: LocalProcessTerminalView) {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak term] event in
            guard let term, event.window === term.window, event.deltaY != 0 else { return event }
            let local = term.convert(event.locationInWindow, from: nil)
            guard term.bounds.contains(local) else { return event }
            // Normal buffer with history: let SwiftTerm scroll the scrollback.
            if term.canScroll { return event }
            // Alternate buffer (full-screen app): send arrow keys instead.
            let notches = max(1, min(Int(abs(event.deltaY).rounded()), 4))
            let up = event.deltaY > 0
            let seq: [UInt8] = term.terminal.applicationCursor
                ? (up ? EscapeSequences.moveUpApp : EscapeSequences.moveDownApp)
                : (up ? EscapeSequences.moveUpNormal : EscapeSequences.moveDownNormal)
            for _ in 0..<notches { term.send(seq) }
            return nil
        }
    }

    /// The Tusk workspace folder (`~/TuskProjects`), created if it doesn't exist so
    /// Claude Code always has a home even when Tusk wasn't installed via `make install`.
    static func workspaceDirectory() -> String {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("TuskProjects")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
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
            ClaudeMark(size: 13)
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
