import AppKit
import SwiftUI

/// 以 SPM 可执行文件方式启动时，默认不会成为常规 GUI 应用（无 Dock 图标、无法获得焦点）。
/// 这里显式切到 `.regular` 并激活，使 `swift run` 与 `.app` bundle 两种方式行为一致。
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct RDPConnectorApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("RDP Connector") {
            RootView()
                .environmentObject(model)
        }
        .defaultSize(width: 560, height: 440)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建连接…") { model.beginCreate() }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}

/// 根视图：无会话时展示连接管理器，有会话时展示会话窗口。
struct RootView: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if let session = model.session {
                SessionView(controller: session)
            } else {
                ProfileListView()
            }
        }
        .sheet(isPresented: $model.isEditorPresented) {
            if let profile = model.editorProfile {
                ProfileEditView(
                    profile: profile,
                    isNew: model.store.profile(id: profile.id) == nil,
                    hadStoredPassword: model.store.hasPassword(for: profile.id))
            }
        }
        .alert(
            "提示",
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } })
        ) {
            Button("好") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
    }
}
