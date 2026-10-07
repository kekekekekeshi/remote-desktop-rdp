import Foundation

/// 把 FreeRDP 的原始错误转成对用户真正有帮助的说明。
///
/// **为什么需要**：FreeRDP 的 `ERRCONNECT_LOGON_FAILURE` 只给出 "Logon failed."，
/// 而本场景下它最常见的成因是「填了 Linux 系统密码，而不是 RDP 凭据」。
/// 直接展示原始文案，用户只会以为程序有 bug，然后反复重试同一个错误。
///
/// 另一层意义：gnome-remote-desktop 在凭据不匹配时，**正确密码、错误密码、
/// 不存在的用户返回的错误完全相同**（失败发生在凭据比对之前，见
/// `docs/spike-result.md`）。所以这类错误无法靠文案区分，只能靠引导。
public enum RDPErrorHint {

    /// 为已知错误补充可操作的说明；无法识别时原样返回。
    public static func enrich(_ message: String) -> String {
        if message.contains("ERRCONNECT_LOGON_FAILURE") {
            return """
                \(message)

                用户名或密码不正确。

                这里要填的是 Ubuntu 端「设置 → 系统 → 远程桌面 → 远程登录」面板里
                设置的 RDP 凭据，**不是 Linux 系统登录密码**。

                两者是两套东西：RDP 凭据用于通过 NLA 握手，进入 GDM 登录页后才用
                Linux 系统密码。即使你在 Ubuntu 上把两者设成了同一个，也请确认
                用户名是那个被授权远程登录的账号。

                可在 Ubuntu 上执行以下命令查看当前生效的 RDP 用户名：
                    sudo grdctl --system status
                """
        }

        if message.contains("ERRINFO_LOGOFF_BY_USER") {
            return """
                \(message)

                服务端主动结束了这个会话。gnome-remote-desktop 在以下情况会这样做：
                  · 同一账号在别处登录（物理控制台或其他远程会话），
                    系统级「远程登录」只保留一个会话
                  · 远程登录创建的 GDM 会话被关闭
                  · 会话空闲超时

                重新连接即可。若频繁发生，请确认没有在其他地方登录同一账号。
                """
        }

        if message.contains("ERRCONNECT_TLS_CONNECT_FAILED") {
            return """
                \(message)

                TLS 握手失败，通常是服务端证书未被信任。
                重新连接时应会弹出证书指纹确认；确认后即可继续。
                """
        }

        if message.contains("ERRCONNECT_HYBRID_REQUIRED_BY_SERVER") {
            return """
                \(message)

                服务端要求使用 NLA（CredSSP），但客户端未启用。
                这通常说明连接参数被改坏了；请恢复默认设置后重试。
                """
        }

        if message.contains("ERRCONNECT_CONNECT_TRANSPORT_FAILED") {
            return """
                \(message)

                传输层失败，常见原因：
                  · 主机地址或端口不对
                  · 服务端 gnome-remote-desktop 未运行，或未开启「远程登录」
                  · 防火墙拦截 3389 端口
                """
        }

        return message
    }
}
