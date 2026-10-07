import SwiftUI

/// 首次连接（TOFU）时的服务端证书确认弹窗。
///
/// gnome-remote-desktop 使用自签名证书，无法用公共 CA 验证。
/// 这里把指纹交给用户确认；确认后写入配置，后续连接自动信任。
struct CertificatePromptView: View {

    @ObservedObject var controller: SessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 26))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("无法验证服务端身份")
                        .font(.headline)
                    Text(controller.profile.endpoint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("这是第一次连接该服务端。gnome-remote-desktop 使用自签名证书，"
                 + "系统无法自动验证其身份。请核对下面的证书指纹是否与你 Ubuntu 上的证书一致。")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("SHA-256 指纹")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(controller.pendingFingerprint ?? "（未获取到指纹）")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Text("在 Ubuntu 上执行以下命令可查看正确指纹：\n"
                 + "sudo grdctl --system status")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("取消连接") {
                    controller.rejectPendingCertificate()
                }
                .keyboardShortcut(.cancelAction)

                Button("信任并连接") {
                    controller.trustPendingCertificate()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}
