import RDPKit
import SwiftUI

/// 连接管理器：配置列表 + 新增/编辑/删除/连接。
struct ProfileListView: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if model.store.profiles.isEmpty {
                emptyState
            } else {
                list
            }

            Divider()
            footer
        }
        .frame(minWidth: 460, minHeight: 340)
    }

    // MARK: - 组件

    private var header: some View {
        HStack {
            Text("RDP 连接")
                .font(.headline)
            Spacer()
            Button {
                model.beginCreate()
            } label: {
                Label("新建", systemImage: "plus")
            }
            .help("新建连接配置")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "display.2")
                .font(.system(size: 38))
                .foregroundStyle(.tertiary)
            Text("还没有连接配置")
                .foregroundStyle(.secondary)
            Button("新建连接") { model.beginCreate() }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var list: some View {
        List {
            ForEach(model.store.profiles) { profile in
                ProfileRow(profile: profile, hasPassword: model.store.hasPassword(for: profile.id))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.connect(profile) }
                    .contextMenu {
                        Button("连接") { model.connect(profile) }
                        Button("编辑…") { model.beginEdit(profile) }
                        Divider()
                        Button("删除", role: .destructive) { model.delete(profile) }
                    }
            }
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("\(model.store.profiles.count) 个配置")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("双击连接")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// 列表行
private struct ProfileRow: View {

    let profile: RDPProfile
    let hasPassword: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "display")
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName)
                    .fontWeight(.medium)
                Text("\(profile.username) @ \(profile.endpoint)  ·  \(profile.width)×\(profile.height)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !hasPassword {
                Image(systemName: "key.slash")
                    .foregroundStyle(.orange)
                    .help("尚未保存 RDP 凭据密码")
            }
            if profile.trustedFingerprint != nil {
                Image(systemName: "checkmark.shield")
                    .foregroundStyle(.green)
                    .help("已信任服务端证书")
            }
        }
        .padding(.vertical, 3)
    }
}
