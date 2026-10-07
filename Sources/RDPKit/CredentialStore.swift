import Foundation

/// RDP 凭据密码的持久化存储。
///
/// **为什么不用 macOS Keychain**：`make app` 走 ad-hoc 签名（`codesign --sign -`），
/// 其 designated requirement 基于**二进制哈希**，重新打包后哈希变化，系统就把应用
/// 当成另一个 App，Keychain 的 ACL 校验必然失败 —— 表现为**每次连接都弹
/// 「允许访问钥匙串」**。本机没有 Apple Developer 账号，无法用 Developer ID 根治，
/// 因此改为应用自管文件。
///
/// **安全性取舍（重要）**：密码以**明文**写在
/// `~/Library/Application Support/RDPConnector/credentials.json`，
/// 文件权限 0600、所在目录 0700，即只有当前用户可读。
/// 任何能以你的身份运行的进程（含脚本、其他 App）都能读到它 ——
/// 这弱于 Keychain，换来的是「双击即连、不弹窗」。
/// 若某天需要更强保护，把本类的读写换回 `SecItem*` 即可（调用方无需改动）。
///
/// **为什么不加密**：密钥没有比文件本身更安全的存放处（放 Keychain 会退回原问题，
/// 硬编码则等于没有）。只做混淆会给「已加密」的错觉，不如老实标明明文。
///
/// 线程约定：与 `ProfileStore` 一致，读写都在主线程调用。
public final class CredentialStore {

    public enum StoreError: Error, LocalizedError {
        case writeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .writeFailed(let message):
                return "密码写入失败：\(message)"
            }
        }
    }

    private let fileURL: URL

    /// 内存缓存。列表行渲染会频繁调用 `hasPassword`，不缓存就会反复读盘。
    private var cache: [String: String] = [:]

    /// 上次加载失败的可读描述，供上层提示（加载失败时缓存为空，等同于「未保存密码」）
    public private(set) var loadError: String?

    public init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    // MARK: - 读

    /// 是否已保存密码
    public func hasPassword(for account: String) -> Bool {
        cache[account] != nil
    }

    /// 读取密码。未保存时返回 `nil`。
    public func password(for account: String) -> String? {
        cache[account]
    }

    // MARK: - 写

    /// 保存密码。已存在则覆盖。
    public func setPassword(_ password: String, for account: String) throws {
        cache[account] = password
        try persist()
    }

    /// 删除密码。不存在时静默成功（幂等）。
    public func deletePassword(for account: String) throws {
        guard cache.removeValue(forKey: account) != nil else { return }
        try persist()
    }

    // MARK: - 持久化

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        do {
            let data = try Data(contentsOf: fileURL)
            guard !data.isEmpty else { return }
            cache = try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            loadError = "读取已保存的密码失败：\(error.localizedDescription)"
        }
    }

    private func persist() throws {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(cache)

            // 原子写入，避免中途失败留下半截文件
            try data.write(to: fileURL, options: .atomic)

            // 明文密码落盘，权限必须收紧到「仅当前用户可读写」。
            // 原子写会先写临时文件再 rename，权限要在写完之后设。
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)

            loadError = nil
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
    }
}
