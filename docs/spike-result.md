# D1 验证性尖刺 —— 结论

**结论：通过。** FreeRDP 3.x 可以连接 Ubuntu 26.04 的 `gnome-remote-desktop` 系统级 Remote Login，
GFX 图形管线与 H.264 解码链路完全打通，黑屏问题在客户端侧可解。

---

## 1. 环境

| 项 | 值 |
| --- | --- |
| 客户端 OS | macOS 26.6.2 (arm64, build 25G83) |
| 客户端 | FreeRDP **3.32.1**（Homebrew，`/opt/homebrew/opt/freerdp`） |
| 客户端二进制 | `sdl-freerdp`（SDL3 后端，`WITH_CLIENT_SDL3=ON`） |
| 服务端 | Ubuntu **26.04.1 LTS**，主机名 `eashion-System-Product-Name` |
| 服务端组件 | `gnome-remote-desktop` **50.2**-0ubuntu0.1（GNOME 50） |
| 服务端模式 | **Remote Login**（系统级 daemon，`gnome-remote-desktop.service`） |
| 端口 | **3389**（系统级 Remote Login）；3390 在用户关闭 Desktop Sharing 后不再监听 |

## 2. 风险项结论（doc.md 第 4.3 节的 R1–R4）

| 编号 | 结论 | 证据 |
| --- | --- | --- |
| **R1** Homebrew freerdp 是否含 H.264 | ✅ **是** | `WITH_FFMPEG=ON`、`WITH_GFX_H264=ON`、`WITH_VIDEO_FFMPEG=ON`、`WITH_DSP_FFMPEG=ON`、`WITH_SWSCALE=ON`；`otool -L libfreerdp3.dylib` 显示已链接 `libavcodec/libavutil/libswscale` |
| **R2** GFX/NLA settings 字段名 | ✅ 已确认 | `FreeRDP_NegotiateSecurityLayer`(1096)、`FreeRDP_IgnoreCertificate`(1408)、`FreeRDP_GfxH264`(3844)、`FreeRDP_GfxAVC444`(3845)、`FreeRDP_GfxAVC444v2`(3847)、`FreeRDP_GfxCapsFilter`(3848)、`FreeRDP_RedirectClipboard`(4800)、`FreeRDP_SupportDynamicChannels`(5059)、`FreeRDP_SupportDisplayControl`(5185)。注意 `FreeRDP_SupportGraphicsPipeline`(142) 已标记 deprecated，应改用 `FreeRDP_GfxProgressive/GfxAVC444` 系列 |
| **R3** GFX 帧是否可从客户端取到 | ✅ 已确认有帧 | 日志持续出现 `logSurfaceCommand: Got GFX RDPGFX_CODECID_AVC420`（26 秒内连续收帧）。具体取帧路径（`gdi->primary_buffer` vs `rdpgfx` 表面回调）留待 Task 6 实现时确认 |
| **R4** pkg-config 是否可用 | ✅ 是 | `pkg-config --modversion freerdp3` → `3.32.1`；提供 `freerdp3.pc`、`freerdp-client3.pc`、`winpr3.pc`；头文件在 `include/freerdp3`、`include/winpr3` |

## 3. 关键发现

### 3.1 服务端强制 NLA（已证实）

```
/sec:tls  → ERRCONNECT_HYBRID_REQUIRED_BY_SERVER [0x0002001E]
/sec:rdp  → ERRCONNECT_HYBRID_REQUIRED_BY_SERVER [0x0002001E]
/sec:nla  → 可进入握手
```

服务端明确拒绝非 NLA 的安全协商。客户端必须启用 NLA/CredSSP。

### 3.2 【重要】Remote Login 的 NLA 凭据 ≠ Linux 系统密码

这是本次排查最关键的发现，**直接影响应用设计**：

- 对 `gnome-remote-desktop-daemon` 做 `ldd` / `nm -D`：
  **完全没有链接 `libpam`，也没有任何 `pam_authenticate` 符号**
- 但链接了 `libsecret-1.so.0`，二进制内含字符串：
  `GrdCredentialsFile`、`GrdCredentialsLibsecret`、`GrdCredentialsOneTime`、`GrdCredentialsTpm`、
  `credentials.ini`、`GRD_RDP_AUTH_METHOD_CREDENTIALS`、`GetSystemCredentials`

**含义**：系统级 daemon 的 NLA 认证**不校验 Linux 账号密码**，而是把客户端提交的凭据与
它**自己存储的 RDP 凭据对**（由 `grdctl --system rdp set-credentials` 或设置面板写入）比对。

**排查中观察到的决定性现象**：在凭据未正确配置前，
"正确密码 / 错误密码 / 不存在的用户 / 空密码" 四种输入返回**完全相同**的
`ERRCONNECT_LOGON_FAILURE [0x00020014]`——证明失败发生在凭据比对之前（存的那组对不上）。
在 `grdctl --system rdp set-credentials` 正确设置后，错误密码才恢复为可区分的失败。

> **对 doc.md 的修正**：doc.md 第 5.2/5.3/13 节把"用户名+密码"默认为 Linux 系统凭据。
> 实际应为**用户在 Ubuntu「设置 → 系统 → 远程桌面 → 远程登录」面板中单独设置的 RDP 凭据**。
> 应用 UI 应使用"RDP 凭据"而非"系统账号"的措辞，并提示用户该凭据需在 Ubuntu 端设置。

### 3.3 两阶段认证流程（实际）

1. **NLA 阶段**：用 RDP 凭据完成 CredSSP 握手（服务端比对自身存储的凭据对）
2. **GDM 阶段**：NLA 通过后进入 GDM 登录页，此时输入 Linux 系统密码登录桌面

## 4. 可用参数组合（已实测）

```bash
sdl-freerdp \
  /v:192.168.1.5:3389 \
  /u:<RDP用户名> \
  /p:<RDP密码> \
  /cert:ignore \
  /gfx:AVC444 \
  +dynamic-resolution \
  /network:auto \
  +clipboard \
  /log-level:INFO
```

**实测协商结果**：

| 项 | 结果 |
| --- | --- |
| 安全协商 | `RDP_NEG_RSP::flags = { |EXTENDED_CLIENT_DATA_SUPPORTED |DYNVC_GFX_PROTOCOL_SUPPORTED |RESTRICTED_ADMIN_MODE_SUPPORTED }` |
| 动态通道 | `dvcman_load_addin: Loading Dynamic Virtual Channel rdpgfx` |
| GFX 能力 | 客户端广播 `RDPGFX_CAPVERSION_8` … `RDPGFX_CAPVERSION_107` |
| 服务端选定 | **`RDPGFX_CAPVERSION_107 [0x000A0701]`**，flags `0x00000002` |
| 画面 | `ResetGraphics 1024x768` → `CreateSurface 1024x768` → `MapSurfaceToOutput` |
| 编码 | **`RDPGFX_CODECID_AVC420`**（H.264 4:2:0）—— 服务端选择 AVC420 而非 AVC444 |
| 持续收帧 | 13:01:53 → 13:02:19，约 26 秒连续收帧后被脚本主动终止 |

> 注：客户端请求 `/gfx:AVC444`，服务端实际下发 AVC420。这是服务端的选择，两者都可用。
> 应用无需强制 AVC444，保持客户端能力广播完整即可。

## 5. 与 mstsc 行为差异的解释

| 客户端 | 结果 | 原因 |
| --- | --- | --- |
| Windows mstsc | ✅ 正常到 GDM 登录页 | 完整实现 MS-RDPEGFX + NLA |
| 微软 macOS 客户端 | ❌ 黑屏 | 对 gnome-remote-desktop 的长期协议 bug |
| Remmina / FreeRDP 2.x | ❌ 黑屏 | GFX 协商失败，服务端拒绝或只推黑帧 |
| **FreeRDP 3.32.1（本方案）** | ✅ **GFX + AVC420 正常** | 完整宣告 GFX capversion 107 + H.264 |

## 6. 遗留事项

1. **待人工确认**：连接期间窗口内是否正常显示 Ubuntu GDM 登录页（日志已证明有帧流，需视觉确认）
2. **凭据语义**：应用需按"RDP 凭据"设计（见 3.2），doc.md 待同步修正
3. **GDM 登录**：`ttt` 用户无 home 目录（`/home/ttt` 不存在）、无附加组，可能在 GDM 登录阶段有影响，需实测
4. **取帧路径**：Task 6 需确认 `gdi->primary_buffer` 能否拿到 GFX 解码后的合成结果

## 7. 复现命令

```bash
# 依赖
brew install freerdp

# 能力自检
sdl-freerdp --version
sdl-freerdp /buildconfig | grep -oE 'WITH_(FFMPEG|GFX_H264)=[A-Z]+'
pkg-config --modversion freerdp3

# 完整验证（脚本形式见 scripts/validate-rdp.sh）
sdl-freerdp /v:192.168.1.5:3389 /u:<RDP用户名> /p:<RDP密码> /cert:ignore \
  /gfx:AVC444 +dynamic-resolution /network:auto +clipboard /log-level:DEBUG
```

---

## 8. 【D2 实现踩坑记录】在自有客户端里嵌入 libfreerdp 的四个必要条件

用 `sdl-freerdp` 命令行能连上，**不代表**在自有代码里用 `freerdp_*` 裸 API 就能连上。
以下四点缺任何一个，症状都是同一个：**服务端在能力交换阶段回 `DEACTIVATE_ALL` 并断开**
（`ERRCONNECT_CONNECT_TRANSPORT_FAILED [0x0002000D]`，日志里
`expected PDU_TYPE_DEMAND_ACTIVE[0x1], got PDU_TYPE_DEACTIVATE_ALL[0x6]`），
极难从表象反推。已全部在 `Sources/RDPBridge/rdp_bridge.c` 中以注释固化。

### 8.1 通道插件必须加载，且必须通过 `LoadChannels` 回调加载

gnome-remote-desktop 强制要求 MS-RDPEGFX，而 GFX 由动态通道 `drdynvc` 承载。
通道不加载 → 客户端不宣告 GFX → 服务端直接断开。

但「加载通道」这件事有三个坑叠在一起：

1. **Homebrew 的 FreeRDP 把通道静态编译进 `libfreerdp-client3`**，磁盘上没有任何
   插件文件（`lib/freerdp3/` 下只有 `proxy`）。FreeRDP 默认按文件名动态加载会失败：
   `freerdp_load_channel_addin_entry: Failed to load channel cliprdr [(null)]`。
   → 需 `freerdp_register_addin_provider()` 注册一个走静态表的 provider
   （转发到 `freerdp_channels_load_static_addin_entry`）。

2. **`freerdp_client_add_static_channel(settings, count, params)` 的 `count` 是
   `params` 数组长度，`params[0]` 才是通道名**，其余元素是通道选项。
   把多个名字塞进一个数组只会注册第一个。必须每个通道单独调用一次。

3. **最关键**：`freerdp_connect_begin()` 在回调 `PreConnect` **之后**会调用
   `utils_reload_channels()`，该函数会 **销毁并重建** 通道管理器，然后回调
   `instance->LoadChannels(instance)` 重新加载通道。
   若 `LoadChannels` 为空（默认），在 `PreConnect` 里辛苦加载的通道会被整体丢弃。
   → 必须设置 `instance->LoadChannels = <加载函数>`。
   FreeRDP 客户端公共层同样如此（`x_client.c: instance->LoadChannels = freerdp_client_load_channels`）。

   验证方法：连接前打印 `FreeRDP_ChannelCount`；正确实现时 MCS 阶段会打印出
   `rdp_client_skip_mcs_channel_join: rdpdr [1004] rdpsnd [1005] cliprdr [1006] drdynvc [1007]`。
   （若为 0，该函数不会输出任何通道，且服务端分配的 `messageChannelId` 停在 1004 而非 1008。）

### 8.2 必须提供 `update->DesktopResize` 回调

GFX 的 `ResetGraphics` PDU 处理路径里有硬断言：

```
winpr_int_assert: ((update->DesktopResize)) [libfreerdp/gdi/gfx.c:gdi_ResetGraphics:130]
```

Homebrew 构建开启了 `WITH_VERBOSE_WINPR_ASSERT=ON`，断言即致命错误，进程直接 abort。
回调内应调用 `gdi_resize(gdi, width, height)` 重建本地帧缓冲，并通知上层。

### 8.3 GFX 帧要显式接到 GDI 上

`gdi_init(instance, PIXEL_FORMAT_BGRA32)` 之后，还必须在通道连接事件里调用
`gdi_graphics_pipeline_init(context->gdi, gfx)`，否则 H.264 解码结果不会合成进
`gdi->primary_buffer`，画面恒为空。GFX 上下文通过订阅 PubSub 的 `ChannelConnected`
事件取得（`e->name == RDPGFX_DVC_CHANNEL_NAME`）。

注意不要图省事用 `freerdp_client_OnChannelConnectedEventHandler()`：它假定传入的是
客户端公共层的 `rdpClientContext`，与裸 `rdpContext` 不兼容。

### 8.4 断开必须在事件循环线程上执行

`freerdp_disconnect()` 与连接一样是有状态且非线程安全的。从 UI 线程直接调用，
虽然事件循环能退出，但随后的 `freerdp_context_free()` 会让进程 **SIGABRT**。

正确做法：`rdp_session_disconnect()` 只置停止标志，事件循环（轮询周期 100ms）
自行退出并调用 `freerdp_disconnect()`，保证连接/断开同线程。

### 8.5 服务端会发起重定向（handover）

连接建立后，服务端会下发 RDP 重定向 PDU，把会话移交给每用户会话 daemon：

```
rdp_recv_server_redirection_pdu: flags: 0x0400,
  redirFlags: LB_LOAD_BALANCE_INFO|LB_USERNAME|LB_PASSWORD|LB_PASSWORD_IS_PK_ENCRYPTED|LB_REDIRECTION_GUID|LB_TARGET_CERTIFICATE
```

FreeRDP 会自动跟随重定向并重新走一遍通道加载，因此 `LoadChannels` 会被调用多次 ——
实现必须是可重入的（这也是它叫 "LoadChannels" 而不是 "PreConnect 一次性初始化" 的原因）。

### 8.6 验证结论

`Sources/RDPBridgeCLI`（开发用验证工具）实测输出：

```
== 创建会话 ==
== 连接 ==
[事件] CONNECTING
[事件] CONNECTED
[事件] RESIZE: 1024x768
[帧] 首帧到达 1024x768 stride=4096
[输入] 已注入 鼠标/滚轮/字符/Shift/Ctrl+Alt+Del/Resize，无崩溃
[事件] DISCONNECTED
== 事件循环结束 ==
== 总帧数: 1 ==          （GDM 登录页为静态画面，无变化时服务端不推帧，符合预期）
EXIT=0
```

输入注入已确认真正送达服务端并产生效果：在 GDM 登录页发送 `Ctrl+Alt+Del` 后，
服务端返回 `ERRINFO_LOGOFF_BY_USER`（会话被登出）。

