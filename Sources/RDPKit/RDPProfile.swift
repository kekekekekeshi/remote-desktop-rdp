import Foundation

/// 一条 RDP 连接配置。
///
/// **关于凭据**：`username` 是 **RDP 凭据用户名**，即在 Ubuntu 端
/// 「设置 → 系统 → 远程桌面 → 远程登录」中单独设置的那一组，**不是** Linux 系统账号。
/// gnome-remote-desktop 的认证分两阶段：NLA 阶段校验这组 RDP 凭据，
/// 通过后才进入 GDM 登录页，在那里输入 Linux 系统密码。
///
/// **密码不入此结构体**，单独存在应用私有文件里
/// （`~/Library/Application Support/RDPConnector/credentials.json`，见 `CredentialStore`），
/// 因此本结构体可以安全地以 JSON 落盘。
public struct RDPProfile: Codable, Identifiable, Hashable {

    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var domain: String
    public var width: Int
    public var height: Int
    /// 请求服务端随窗口尺寸调整分辨率（需服务端支持 Display Control）
    public var dynamicResolution: Bool
    /// 启用剪贴板重定向
    public var clipboard: Bool
    /// TOFU：已信任的服务端证书指纹（sha256）。`nil` 表示尚未信任。
    public var trustedFingerprint: String?
    /// Command 键在远端扮演 Ctrl 还是 Win 键，见 `CmdKeyBehavior`
    public var cmdKeyBehavior: CmdKeyBehavior

    public init(
        id: UUID = UUID(),
        name: String = "",
        host: String = "",
        port: Int = 3389,
        username: String = "",
        domain: String = "",
        width: Int = 1920,
        height: Int = 1080,
        dynamicResolution: Bool = true,
        clipboard: Bool = true,
        trustedFingerprint: String? = nil,
        cmdKeyBehavior: CmdKeyBehavior = .control
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.domain = domain
        self.width = width
        self.height = height
        self.dynamicResolution = dynamicResolution
        self.clipboard = clipboard
        self.trustedFingerprint = trustedFingerprint
        self.cmdKeyBehavior = cmdKeyBehavior
    }

    // MARK: - Codable
    //
    // 手写 init(from:) 而不是用合成的：新增字段（cmdKeyBehavior）必须能从
    // **旧版 profiles.json**（没有该字段）里读出来并取默认值。用合成的 decoder
    // 会因 keyNotFound 直接抛错，整个配置列表都会加载失败。

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, domain, width, height
        case dynamicResolution, clipboard, trustedFingerprint, cmdKeyBehavior
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        domain = try container.decode(String.self, forKey: .domain)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
        dynamicResolution = try container.decode(Bool.self, forKey: .dynamicResolution)
        clipboard = try container.decode(Bool.self, forKey: .clipboard)
        trustedFingerprint = try container.decodeIfPresent(String.self, forKey: .trustedFingerprint)

        // 旧配置没有这个字段，缺省取「Cmd 当 Ctrl」——即 Mac 用户预期的复制粘贴行为
        cmdKeyBehavior = try container.decodeIfPresent(CmdKeyBehavior.self, forKey: .cmdKeyBehavior)
            ?? .control
    }

    /// 列表中展示用的名称：未命名时回退到 `用户名@主机`
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if username.isEmpty { return host }
        return "\(username)@\(host)"
    }

    /// 目标描述，如 `192.168.1.5:3389`
    public var endpoint: String {
        port == 3389 ? host : "\(host):\(port)"
    }

    /// 校验结果。返回空数组表示可用于连接。
    public var validationIssues: [String] {
        var issues: [String] = []

        if host.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append("主机地址不能为空")
        }
        if port < 1 || port > 65535 {
            issues.append("端口需在 1–65535 之间")
        }
        if username.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append("RDP 凭据用户名不能为空")
        }
        if width < 200 || height < 200 {
            issues.append("分辨率过小")
        }
        return issues
    }

    public var isValid: Bool { validationIssues.isEmpty }
}
