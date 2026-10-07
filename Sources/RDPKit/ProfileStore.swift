import Combine
import Foundation

/// 连接配置的持久化存储。
///
/// 落盘位置：
///   - `~/Library/Application Support/RDPConnector/profiles.json`（配置本身）
///   - `~/Library/Application Support/RDPConnector/credentials.json`（密码，0600）
///
/// 密码**不放 Keychain**，原因见 `CredentialStore`。
///
/// 线程约定：读写都应在主线程调用（UI 直接绑定本对象）。
public final class ProfileStore: ObservableObject {

    @Published public private(set) var profiles: [RDPProfile] = []

    /// 最近一次读/写失败的可读描述，供 UI 展示
    @Published public private(set) var lastError: String?

    private let fileURL: URL
    private let credentials: CredentialStore

    public init(fileURL: URL? = nil) {
        let resolved = fileURL ?? Self.defaultFileURL()
        self.fileURL = resolved
        // 凭据与配置同目录：自定义路径（如自检用的临时目录）也能整目录隔离
        self.credentials = CredentialStore(
            fileURL: resolved.deletingLastPathComponent()
                .appendingPathComponent("credentials.json"))
        load()
        if let error = credentials.loadError { lastError = error }
    }

    /// 默认存储路径
    public static func defaultFileURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("RDPConnector", isDirectory: true)
            .appendingPathComponent("profiles.json")
    }

    // MARK: - 查询

    public func profile(id: UUID) -> RDPProfile? {
        profiles.first { $0.id == id }
    }

    private func index(of id: UUID) -> Int? {
        profiles.firstIndex { $0.id == id }
    }

    // MARK: - 增删改

    public func add(_ profile: RDPProfile) {
        profiles.append(profile)
        save()
    }

    public func update(_ profile: RDPProfile) {
        guard let i = index(of: profile.id) else { return }
        profiles[i] = profile
        save()
    }

    /// 删除配置，并连带清理已保存的密码。
    public func remove(id: UUID) {
        guard let i = index(of: id) else { return }
        profiles.remove(at: i)

        do {
            try credentials.deletePassword(for: id.uuidString)
        } catch {
            // 密码清理失败不应阻断配置删除，但要可见
            lastError = error.localizedDescription
        }
        save()
    }

    // MARK: - 密码（转发到 CredentialStore）

    public func password(for id: UUID) -> String? {
        credentials.password(for: id.uuidString)
    }

    public func setPassword(_ password: String, for id: UUID) throws {
        try credentials.setPassword(password, for: id.uuidString)
    }

    /// 删除已保存的密码（幂等）
    public func removePassword(for id: UUID) throws {
        try credentials.deletePassword(for: id.uuidString)
    }

    /// 是否已保存密码
    public func hasPassword(for id: UUID) -> Bool {
        credentials.hasPassword(for: id.uuidString)
    }

    // MARK: - 持久化

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        do {
            let data = try Data(contentsOf: fileURL)
            profiles = try JSONDecoder().decode([RDPProfile].self, from: data)
        } catch {
            lastError = "读取配置失败：\(error.localizedDescription)"
        }
    }

    private func save() {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(profiles)

            // 原子写入，避免中途失败留下半截文件
            try data.write(to: fileURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = "保存配置失败：\(error.localizedDescription)"
        }
    }
}
