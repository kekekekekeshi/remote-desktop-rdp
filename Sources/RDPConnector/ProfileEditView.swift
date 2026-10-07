import RDPKit
import SwiftUI

/// 配置编辑器。
///
/// 注意：视图局部状态用 `LocalState` + `@StateObject` 承载而非 `@State`，
/// 原因见 `LocalState.swift`（CLT 环境缺少 SwiftUI 宏插件）。
struct ProfileEditView: View {

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @StateObject private var draft: LocalState<RDPProfile>
    @StateObject private var password: LocalState<String>
    @StateObject private var showPassword = LocalState(false)
    @StateObject private var clearPassword = LocalState(false)
    /// 进入编辑器时该配置是否已有密码（决定是否显示「清除已保存的密码」）
    private let hadStoredPassword: Bool

    private let isNew: Bool

    init(profile: RDPProfile, isNew: Bool, hadStoredPassword: Bool) {
        _draft = StateObject(wrappedValue: LocalState(profile))
        _password = StateObject(wrappedValue: LocalState(""))
        self.isNew = isNew
        self.hadStoredPassword = hadStoredPassword
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                // 数值输入统一禁用千位分隔符：端口 3389 显示成 "3,389"、
                // 分辨率 1920 显示成 "1,920" 都是本地区域化格式带来的误导。
                Section("连接") {
                    TextField("名称（可选）", text: $draft.value.name,
                              prompt: Text("例如：办公室 Ubuntu"))

                    TextField("主机", text: $draft.value.host, prompt: Text("192.168.1.5"))

                    TextField("端口", value: $draft.value.port, format: .number.grouping(.never))

                    TextField("域名（可选）", text: $draft.value.domain)
                }

                Section {
                    TextField("RDP 凭据用户名", text: $draft.value.username)

                    if showPassword.value {
                        TextField("密码", text: $password.value,
                                  prompt: Text(passwordPrompt))
                    } else {
                        SecureField("密码", text: $password.value,
                                    prompt: Text(passwordPrompt))
                    }

                    Toggle("显示密码", isOn: $showPassword.value)
                        .toggleStyle(.checkbox)

                    if hadStoredPassword {
                        Toggle("清除已保存的密码", isOn: $clearPassword.value)
                            .toggleStyle(.checkbox)
                    }
                } header: {
                    Text("凭据")
                } footer: {
                    Text("这里填的是 Ubuntu 端「设置 → 系统 → 远程桌面 → 远程登录」"
                         + "面板中单独设置的 RDP 凭据，不是 Linux 系统登录密码。"
                         + "NLA 握手用它；通过后进入 GDM 登录页，在那里再输入 Linux 系统密码。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section {
                    Picker("分辨率", selection: resolutionSelection) {
                        ForEach(ResolutionPreset.builtIn) { preset in
                            Text(preset.label).tag(preset.id)
                        }
                        Divider()
                        Text("自定义").tag(Self.customResolutionID)
                    }

                    HStack {
                        TextField("宽", value: $draft.value.width, format: .number.grouping(.never))
                        Text("×")
                        TextField("高", value: $draft.value.height, format: .number.grouping(.never))
                    }

                    Toggle("窗口变化时请求远端调整分辨率", isOn: $draft.value.dynamicResolution)
                    Toggle("启用剪贴板同步", isOn: $draft.value.clipboard)
                } header: {
                    Text("显示")
                } footer: {
                    Text("分辨率只是首次连接请求的尺寸。勾选上面一项后，"
                         + "连上之后远端会跟随窗口大小自行调整，这里的值不再起作用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section {
                    Picker("Command 键", selection: $draft.value.cmdKeyBehavior) {
                        ForEach(CmdKeyBehavior.allCases) { behavior in
                            Text(behavior.displayName).tag(behavior)
                        }
                    }
                } header: {
                    Text("键盘")
                } footer: {
                    Text(draft.value.cmdKeyBehavior.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if draft.value.trustedFingerprint != nil {
                    Section("安全") {
                        HStack {
                            Text("已信任服务端证书")
                            Spacer()
                            Button("清除指纹") {
                                draft.value.trustedFingerprint = nil
                            }
                            .help("清除后下次连接会重新询问是否信任")
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if !draft.value.validationIssues.isEmpty {
                    Label(draft.value.validationIssues.joined(separator: "；"),
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }

                Spacer()

                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button(isNew ? "创建" : "保存") {
                    model.saveEditor(draft.value,
                                     password: password.value,
                                     clearPassword: clearPassword.value)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.value.isValid)
            }
            .padding(12)
        }
        .frame(width: 480, height: 580)
    }

    /// 密码框的占位提示。
    ///
    /// 编辑器**不预填**已保存的密码：留空即保持原样，避免误覆盖；
    /// 要修改就直接填入新值。
    private var passwordPrompt: String {
        hadStoredPassword ? "已保存（留空则不修改）" : "RDP 凭据密码"
    }

    // MARK: - 分辨率预设

    private static let customResolutionID = "custom"

    /// 分辨率下拉的选择值。
    ///
    /// 不额外存状态：直接由 `draft` 的宽高推导 —— 命中内置预设就显示预设，
    /// 否则显示「自定义」。这样手动改宽高会自动落到「自定义」，两边不会打架。
    private var resolutionSelection: Binding<String> {
        Binding(
            get: {
                let id = ResolutionPreset.id(width: draft.value.width, height: draft.value.height)
                let matchesPreset = ResolutionPreset.builtIn.contains { $0.id == id }
                return matchesPreset ? id : Self.customResolutionID
            },
            set: { newValue in
                // 选中「自定义」时不动宽高，保留当前值让用户接着改
                guard let preset = ResolutionPreset.builtIn.first(where: { $0.id == newValue })
                else { return }
                draft.value.width = preset.width
                draft.value.height = preset.height
            }
        )
    }
}
