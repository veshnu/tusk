import SwiftUI
import AppKit

@main
struct TuskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var store = ConnectionStore()

    var body: some Scene {
        Window("Tusk", id: "main") {
            RootView()
                .environmentObject(model)
                .environmentObject(store)
                .environment(\.palette, model.palette)
                .preferredColorScheme(model.isDark ? .dark : .light)
                .frame(minWidth: 940, minHeight: 620)
                .onAppear { model.connectionStore = store }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// MARK: - Root routing

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.palette) var pal

    var body: some View {
        ZStack {
            pal.surfaceApp.ignoresSafeArea()
            switch model.route {
            case .connect:
                ConnectScreen()
            case .workspace:
                Workspace()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.route)
    }
}
