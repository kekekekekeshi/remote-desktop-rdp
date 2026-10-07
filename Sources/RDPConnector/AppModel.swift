import Combine
import Foundation
import RDPKit
import SwiftUI

/// 应用级共享状态：配置列表、编辑器呈现、当前会话。
@MainActor
final class AppModel: ObservableObject {

    let store: ProfileStore

    /// 当前会话；非 nil 时展示会话窗口
    @Published var session: SessionController?

    /// 编辑器呈现状态
    @Published var editorProfile: RDPProfile?
    @Published var isEditorPresented = false

    /// 全局提示（配置读写失败、密码缺失等）
    @Published var alertMessage: String?

    private var cancellables = Set<AnyCancellable>()

    /// 底层 FreeRDP 构建能力，启动时自检一次
    let capabilities = RDPCapabilities.detect()

    init(store: ProfileStore = ProfileStore()) {
        self.store = store

        // ProfileStore 是独立的 ObservableObject，这里把它的变更转发出去，
        // 使绑定 AppModel 的视图能感知配置列表变化
        store.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // 缺少 GFX/H.264 能力时，连接 gnome-remote-desktop 会「连上但黑屏」。
        // 与其让用户对着黑屏排查，不如启动就说明。
        if let message = capabilities.missingCapabilityMessage {
            alertMessage = message
        }
    }

    // MARK: - 编辑器

    func beginCreate() {
        editorProfile = RDPProfile()
        isEditorPresented = true
    }

    func beginEdit(_ profile: RDPProfile) {
        editorProfile = profile
        isEditorPresented = true
    }

    /// 保存编辑器内容。
    ///
    /// 密码三态语义（编辑器**不预填**已保存的密码，留空即表示不改）：
    ///   - `clearPassword == true` → 删除已保存的密码
    ///   - 否则 `password` 非空     → 覆盖保存
    ///   - 否则                     → 保持原样不动
    func saveEditor(_ profile: RDPProfile, password: String?, clearPassword: Bool) {
        let isNew = store.profile(id: profile.id) == nil

        if isNew {
            store.add(profile)
        } else {
            store.update(profile)
        }

        do {
            if clearPassword {
                try store.removePassword(for: profile.id)
            } else if let password, !password.isEmpty {
                try store.setPassword(password, for: profile.id)
            }
        } catch {
            alertMessage = "密码保存失败：\(error.localizedDescription)"
        }

        isEditorPresented = false
        editorProfile = nil
    }

    func delete(_ profile: RDPProfile) {
        store.remove(id: profile.id)
    }

    // MARK: - 会话

    func connect(_ profile: RDPProfile) {
        // 密码来自应用私有文件（非 Keychain），读取不触发任何系统授权弹窗
        let password = store.password(for: profile.id) ?? ""

        guard !password.isEmpty else {
            alertMessage = "该配置尚未保存 RDP 凭据密码，请先编辑配置填入密码。\n"
                + "注意：这里是 Ubuntu 端「远程登录」面板中单独设置的 RDP 凭据，不是 Linux 系统密码。"
            return
        }

        let controller = SessionController(profile: profile, password: password, store: store)
        session = controller
        controller.start()
    }

    func endSession() {
        session?.stop()
        session = nil
    }
}
