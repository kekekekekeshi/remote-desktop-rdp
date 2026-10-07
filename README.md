# RDP Connector

macOS 原生 RDP 客户端，行为对标 Windows 自带的「远程桌面连接」(mstsc)，
用于连接 **Ubuntu 自带的「远程桌面」**（`gnome-remote-desktop`）。

## 为什么需要它

Ubuntu 24.04+ 自带的远程桌面（GNOME 46+）在能力交换阶段**强制要求客户端宣告
MS-RDPEGFX 图形管线并支持 H.264**。不满足时，服务端要么直接关闭连接，要么只推送黑帧。

这导致一个很反直觉的现象：

| 客户端 | 结果 |
| --- | --- |
| Windows mstsc | ✅ 正常，可到达 GDM 登录页 |
| 微软 macOS 客户端（Windows App） | ❌ 黑屏（对 gnome-remote-desktop 有长期协议 bug） |
| Remmina / 基于 FreeRDP 2.x 的客户端 | ❌ 黑屏（GFX 协商失败） |
| **本项目（FreeRDP 3.x）** | ✅ 正常 |

本项目基于 **FreeRDP 3.x** 构建，完整宣告 GFX 能力并支持 H.264 解码。

## 环境要求

- macOS 26+（部署目标与 Homebrew 版 FreeRDP 的构建目标一致）
- Homebrew
- FreeRDP 3.x，且**必须带 H.264 支持**

```bash
brew install freerdp
```

安装后先自检：

```bash
make check
# 期望看到 WITH_FFMPEG=ON 与 WITH_GFX_H264=ON
```

## 构建与运行

```bash
make build      # 编译
make run        # 直接运行（开发用）
make app        # 打包成可双击运行的 .app（自包含，约 44 MB）
make app THIN=1 # 精简打包（约 1 MB，依赖本机已装 FreeRDP）
```

产物在 `build/RDPConnector.app`，双击或 `open build/RDPConnector.app` 即可运行。

> 本机只需要 Command Line Tools（无需安装 Xcode.app）。
> 唯一影响是 SwiftUI 的 `@State` 宏不可用，项目用 `LocalState` 替代，详见
> `Sources/RDPConnector/LocalState.swift`。

## 打包说明

### 为什么需要额外的打包步骤

SPM 只能产出**裸可执行文件**，而 SwiftUI 应用要拿到 Dock 图标、窗口焦点，
以及稳定的 bundle identifier，就必须是 `.app` bundle。
`scripts/build-app.sh` 负责组装 `Contents/{MacOS,Resources,Info.plist}`。

### 自包含：把 FreeRDP 打进 bundle

`make app` 默认做**自包含打包**。原因：程序链接的是 Homebrew 里的 FreeRDP
（绝对路径 `/opt/homebrew/opt/freerdp/lib/...`），换台机器就启动不了：

| 场景 | 精简包（`THIN=1`） | 自包含包（默认） |
| --- | --- | --- |
| 本机（已装 FreeRDP） | ✅ | ✅ |
| 别人的 Apple Silicon Mac，未装 FreeRDP | ❌ 启动即崩 | ✅ |
| Intel Mac（Homebrew 前缀是 `/usr/local`） | ❌ | ✅ |

`scripts/bundle-dylibs.sh` 做的事：

1. 从可执行文件出发**递归收集**所有非系统依赖（本工程实测 32 个，含 ffmpeg / openssl / x264 等）
2. 复制进 `Contents/Frameworks/`
3. 把每个库自身的 id、以及库之间的相互引用改成 `@rpath/<name>`
4. 给可执行文件加 `@executable_path/../Frameworks` 搜索路径
5. 逐个重新签名（先库后 app）

验证自包含是否生效：

```bash
# 可执行文件不应再引用任何 Homebrew 路径
otool -L build/RDPConnector.app/Contents/MacOS/RDPConnector | grep /opt/homebrew

# 运行期确认全部从 bundle 内加载
DYLD_PRINT_LIBRARIES=1 build/RDPConnector.app/Contents/MacOS/RDPConnector 2>&1 | grep -c Frameworks
```

### 分发给别人

上面的自包含包**拷给别人就能用**，但因为是 ad-hoc 签名，对方首次打开会被
Gatekeeper 拦下（提示"无法验证开发者"）。两种处理方式：

- 让对方右键 → 打开，或执行 `xattr -dr com.apple.quarantine <app>`
- 正式分发则需 Apple Developer 账号：用 Developer ID 证书签名 + 公证（notarization）

### 当前没有应用图标

`Contents/Resources` 是空的。要加图标需准备 `.icns` 并在 `Info.plist` 里加
`CFBundleIconFile`。

## 使用说明

### 1. 在 Ubuntu 上准备「远程登录」

在 Ubuntu 打开「设置 → 系统 → 远程桌面」：

1. 打开 **远程登录（Remote Login）**
2. 设置一组 **RDP 凭据**（用户名 + 密码）

> **关键概念**：这组 RDP 凭据**不是**你的 Linux 系统登录密码。
> gnome-remote-desktop 的认证分两阶段：
> 1. **NLA 阶段** —— 用这组 RDP 凭据完成 CredSSP 握手
> 2. **GDM 阶段** —— 通过后进入 GDM 登录页，在那里输入 **Linux 系统密码**
>
> 如果你在 Ubuntu 上把 RDP 凭据设成和系统账号一样（常见做法），两者才恰好相同。
> 排查提示：如果凭据配错，服务端会返回 `LOGON_FAILURE`，而且**正确密码、错误密码、
> 不存在的用户、空密码返回的错误完全相同**——因为失败发生在凭据比对之前。

### 2. 在应用里新建连接

填写主机、端口、RDP 凭据用户名与密码。

分辨率从**内置列表**里选（1024×768 到 3840×2160，共 17 项，带 `FHD` / `QHD` 这类简称），
也可以直接改下面的宽/高数字框 —— 改动会自动落到列表的「自定义」项。
这个值只是**首次连接请求的尺寸**；勾选了「窗口变化时请求远端调整分辨率」之后，
连上后远端会跟随窗口大小自行调整。

「键盘」区选 **Command 键**在远端扮演什么角色，默认 **Ctrl**：

- **Ctrl（默认）**：`Cmd+C` / `Cmd+V` / `Cmd+A` 等按 Linux 习惯生效，符合 Mac 直觉。
  代价：远端的 Win 键（Super）不再可达。
- **Win 键**：保留 Super 以使用系统级快捷键。
  代价：复制粘贴要在远端按 `Ctrl+C` / `Ctrl+V`，按 `Cmd+C` / `Cmd+V` 无效。

> 这一项默认改成 Ctrl 是有原因的：Mac 用户的肌肉记忆是 `Cmd+C` / `Cmd+V`，
> 若把 Cmd 当 Win 键，远端收到的是 `Win+C` / `Win+V`，什么都不会发生 ——
> 表现出来就是「剪贴板不能用」。

首次连接会弹出服务端证书指纹确认（TOFU）。gnome-remote-desktop 使用自签名证书，
无法用公共 CA 验证，需要你核对指纹：

```bash
sudo grdctl --system status     # 在 Ubuntu 上执行，可看到 TLS fingerprint
```

确认后：

- 指纹写入该连接的配置（UI 上显示「已信任」）
- **证书本身由 FreeRDP 存入 `~/.config/freerdp/server/<host>_<port>.pem`**，
  这是信任的权威来源，后续连接不会再询问

若服务端证书发生变化（重装，或存在中间人攻击），FreeRDP 会触发变更回调，
应用一律拒绝并重新提示，需要你显式确认。

> 排障时可临时跳过校验（`RDP_IGNORE_CERT=1`，见开发工具一节），
> 但注意它会把证书直接写进上述信任库，之后不会再出现 TOFU 提示。

### 3. 连接

双击配置即可连接。**连接成功后会自动进入 macOS 原生全屏**，系统菜单栏随之自动隐藏，
窗口工具栏也不再出现。

控制项收在**一个可拖动的把手**里（半透明胶囊 + 箭头）：

- 光标移到把手上 → 控制抽屉从把手所在的那一侧滑出；光标移开 → 自动收起
- **把手可拖到窗口内任意位置，松手自动吸附到最近的一条边**（上/下/左/右）。
  位置会记住，下次连接仍在原处 —— 用来避开远端桌面上的内容
- 吸附在左右边时把手会竖过来，箭头指向抽屉将要出现的方向
- 抽屉内提供：远端分辨率、渲染后端切换、性能指标、发送 `Ctrl+Alt+Del`、全屏切换、断开
- 退出全屏：抽屉里的「全屏」按钮，或把光标顶到屏幕最上方呼出系统菜单栏后用绿色按钮
  （`⌃⌘F` 亦可）。手动退出后不会被强制弹回，但重新连接成功会再次自动全屏

窗口尺寸变化时会请求远端调整分辨率（需服务端支持 Display Control）。

## 架构

```
SwiftUI App (RDPConnector)
  连接管理器 / 会话窗口 / 渲染视图
        ↓
RDPKit (Swift)
  RDPProfile / ProfileStore / CredentialStore / RDPClient / RDPCapabilities
        ↓
RDPBridge (C)          ← 唯一接触 libfreerdp 的地方
  会话生命周期 / settings / 事件循环 / 帧回调 / 输入注入 / 剪贴板
        ↓
libfreerdp3 / libwinpr3 (Homebrew)
```

设计原则：`libfreerdp` 的复杂度全部收敛在 `RDPBridge` 里，Swift 侧只看到朴素的 C ABI。
详细设计见 `.comate/specs/macos-rdp-connector/doc.md`。

### 关键实现约束

在自有代码里嵌入 libfreerdp（而不是用 `sdl-freerdp` 命令行）有四个硬性约束，
缺任何一个的症状都是同一个：**服务端在能力交换阶段回 `DEACTIVATE_ALL` 并断开**，
报错 `ERRCONNECT_CONNECT_TRANSPORT_FAILED [0x0002000D]`，从表象极难反推。

1. **通道必须通过 `instance->LoadChannels` 回调加载**，不能在 `PreConnect` 里加载。
   `freerdp_connect_begin` 会在 `PreConnect` 之后调用 `utils_reload_channels()`，
   它销毁并重建通道管理器，再回调 `LoadChannels` 重新加载。
2. **需注册静态 addin provider**。Homebrew 把通道静态编译进 `libfreerdp-client3`，
   磁盘上没有插件文件，FreeRDP 默认的按文件加载会失败。
3. **必须设置 `update->DesktopResize`**。GFX 的 `ResetGraphics` 路径里有
   `WINPR_ASSERT(update->DesktopResize)`，而该构建开启了 `WITH_VERBOSE_WINPR_ASSERT=ON`，
   断言即 abort。
4. **GFX 必须显式接到 GDI**。订阅 `ChannelConnected` 事件，收到
   `RDPGFX_DVC_CHANNEL_NAME` 时调用 `gdi_graphics_pipeline_init()`，
   否则 H.264 解码帧不会进 `primary_buffer`，画面恒为空。

另：`freerdp_disconnect()` 必须在事件循环线程上调用，从 UI 线程直接调用会在随后的
`freerdp_context_free()` 阶段触发 SIGABRT。

以上均有代码注释，排查记录见 `docs/spike-result.md` 第 8 节。

## 鼠标光标

**RDP 的分工是：服务端只下发光标「形状」，位置与绘制由客户端负责。**
位置之所以由客户端掌握，是因为绝大多数移动都源自客户端自己的鼠标输入；
服务端只在自己主动挪动光标（pointer warp）时才下发位置事件。

`gnome-remote-desktop` 甚至不会把光标合成进视频流（可用 `RDP_DUMP_DIR` 导出帧验证：
画面里没有光标），所以客户端必须自己画，否则用户看不到鼠标指针。

实现要点：

- **形状**：C 桥接层解码 RDP 的 AND/XOR 掩码（1/16/24/32bpp，交给 FreeRDP 的
  `freerdp_image_copy_from_pointer_data` 处理），产出预乘 alpha 的 BGRA32。
  服务端是**懒加载**的：连接时不发，首次光标交互才发。
- **位置**：由渲染视图从自己的鼠标事件推导，无需等服务端。
- **绘制**：在 CPU 侧把光标按 over 合成进画面帧，再交给渲染后端。

之所以在 CPU 侧合成而不是让渲染后端各画各的：Metal 后端受「无着色器」约束
（见下节），`MTLBlitCommandEncoder` 只能原样拷贝、无法做 alpha 混合；
统一在 CPU 侧合成后，两个后端拿到的是同一份最终像素，行为完全一致。
合成只遍历光标包围盒（通常 24×24 ~ 64×64 像素），与整帧尺寸无关。

自检：

```bash
swift run rdpbridge-cli cursor-check /tmp          # 像素级验证 over 合成 + 导出 PNG
```

## 渲染后端

画面渲染有两套可运行时切换的后端，在会话窗口的顶部抽屉里切换（选择会持久化）：

| 后端 | 实现 | 每帧呈现耗时（1920×1080） |
| --- | --- | --- |
| **CoreGraphics**（默认） | `NSImage` 位图绘制到图层后备存储 | **~0.13 ms** |
| Metal | 纹理上传 + `blit` 拷贝到 drawable | ~0.92 ms |

复现：

```bash
make bench                                        # 默认 1920×1080 / 30fps / 5 秒
make bench BENCH_SECONDS=8 BENCH_WIDTH=2560 BENCH_HEIGHT=1440
```

### 结论：当前实现下 Metal 并不更快

这是实测结果，不是预期。原因是：

- **本机没有 Metal 着色器编译器**（`xcrun metal` / `metallib` 随 Xcode 分发，CLT 里没有），
  所以 Metal 后端只能用「上传纹理 + `blit` 拷贝」这条无需着色器的路径。
- `blit` 不支持缩放，因此 `drawableSize` 固定为远端分辨率、由图层负责放大。
- 该路径每帧要多做一次 **CPU→GPU 纹理上传**（1080p 下 8 MB 内存拷贝）；
  而 macOS 上 `NSImage.draw(in:)` 写入图层后备存储已由 CoreGraphics/CoreAnimation
  硬件加速，只需一次拷贝。

基准测试里附带两项交叉验证，避免「快」是因为**根本没渲染**：

- **上传自检**：回读渲染目标像素，与合成帧的已知值比对（Metal 通过）
- **离屏参照测量**：把同一帧同步光栅化到离屏位图，用于判断视图内的耗时是否被延迟
  （实测 0.17 ms，与视图内 0.13 ms 接近，说明数值未失真）

两者在 RDP 帧率下都远未成为瓶颈（0.92 ms vs 30fps 的 33 ms 预算）。

因此**默认使用 CoreGraphics**。Metal 保留为可选项，供后续需要着色器的场景使用：
色彩空间转换、光标合成、脏矩形增量上传、`drawableSize` 跟随视图像素尺寸以获得更锐利的显示。
若将来安装了 Xcode，可以在此基础上引入 `.metal` 着色器。

> 顺带一提：真正的优化空间不在后端选择，而在**只上传变化的区域**。
> 目前 C 桥接层每帧上报整帧（dirty 矩形固定为全屏），
> 改成按 FreeRDP 的 invalid region 增量上报，两条路径都会受益。

## 常见问题

### 连接失败：`ERRCONNECT_LOGON_FAILURE`

用户名或密码不对。**这里要填的是 RDP 凭据，不是 Linux 系统密码** —— 见上文「使用说明」。
应用会在错误里直接给出这条提示。

注意 gnome-remote-desktop 在凭据不匹配时，**正确密码、错误密码、不存在的用户
返回的错误完全相同**（失败发生在凭据比对之前），所以无法靠错误码区分。

### 密码保存在哪里

**不使用 macOS Keychain**，密码写在应用私有文件里：

```
~/Library/Application Support/RDPConnector/credentials.json   # 权限 0600
```

为什么不用 Keychain：`make app` 走 ad-hoc 签名，其 designated requirement 基于
**二进制哈希**，重新打包后哈希变化，系统会把它当成另一个 App，Keychain 的 ACL 校验
必然失败 —— 表现为**每次连接都弹「允许访问钥匙串」**。本机没有 Apple Developer 账号，
无法用 Developer ID 根治，所以干脆不用它。

> **安全取舍**：密码是**明文**落盘的（文件 0600、目录 0700，仅当前用户可读）。
> 任何能以你的身份运行的进程都能读到它。这弱于 Keychain，换来的是「双击即连、不弹窗」。
> 想改回 Keychain，只需替换 `Sources/RDPKit/CredentialStore.swift` 的实现，调用方无需改动。

**从旧版本升级**：之前存在 Keychain 里的密码不会被迁移（迁移需要读 Keychain，
等于又弹一次授权）。请在每个配置里重新填一次密码，之后就不会再弹了。

### 连接时提示「该配置尚未保存 RDP 凭据密码」

密码没保存成功，或刚从使用 Keychain 的旧版本升级过来（密码没有迁移）。
编辑该配置、填入 RDP 凭据密码并保存即可。

### 剪贴板不工作（复制粘贴没反应）

**九成是 Command 键映射的问题。** 在远端里必须按 **`Ctrl+C` / `Ctrl+V`**，
按 `Cmd+C` / `Cmd+V` 在默认配置下是**无效**的（Cmd 被当成 Win 键发过去，
GNOME 收到 `Win+C` / `Win+V` 什么都不做）。

两种解法，任选其一：

- 配置里把「键盘 → Command 键」改成 **Ctrl**（推荐）。之后 `Cmd+C` / `Cmd+V`
  就按 Linux 习惯生效，代价是失去远端的 Win 键（Super）
- 保持默认，在远端里改用 `Ctrl+C` / `Ctrl+V`

排除这一条之后如果仍然不通，检查：

1. 配置里「启用剪贴板同步」是否勾选
2. **远端剪贴板得先有内容**。远端→本地是服务端在剪贴板**变化时**才下发的：
   在 Ubuntu 侧复制一次，Mac 这边才会收到。GDM 登录页上没有可复制的东西，
   所以那个阶段远端→本地必然是空的
3. 自检工具可以看协议层是否通（会真的连一次）：

```bash
swift run rdpbridge-cli kit-check <host> <user> <password> 15
# 期望看到：[剪贴板] 推送本地文本: ... 且不报错
# 用 WLOG_LEVEL=DEBUG 可看到 cliprdr 报文
```

### 提示「服务端结束了会话」(`ERRINFO_LOGOFF_BY_USER`)

服务端主动断开了会话。gnome-remote-desktop 会在以下情况这样做：

- 同一账号在别处登录（物理控制台或其他远程会话）——系统级「远程登录」只保留一个会话
- 远程登录创建的 GDM 会话被关闭
- 会话空闲超时

重新连接即可。

## 排查黑屏

按顺序检查：

1. `make check` —— 确认 FreeRDP 带 H.264（`WITH_FFMPEG=ON` / `WITH_GFX_H264=ON`）
2. 确认连的是 **Remote Login**（系统级，呈现 GDM 登录页），不是 Desktop Sharing
3. 确认 RDP 凭据是 Ubuntu 上「远程登录」面板里设的那组
4. 用验证脚本拿到完整协商日志：

```bash
make spike RDP_HOST=192.168.1.5 RDP_USER=ttt
```

或直接用 FreeRDP 命令行对照：

```bash
sdl-freerdp /v:<host>:3389 /u:<user> /p:<password> /cert:ignore \
  /gfx:AVC444 +dynamic-resolution +clipboard /log-level:DEBUG
```

日志中出现以下内容即表示 GFX 链路正常：

```
dvcman_load_addin: Loading Dynamic Virtual Channel rdpgfx
rdpgfx_recv_caps_confirm_pdu: version: RDPGFX_CAPVERSION_107
logSurfaceCommand: Got GFX RDPGFX_CODECID_AVC420
```

## 开发工具

`rdpbridge-cli` 是不经 GUI 直接驱动各层的验证工具（非交付物）：

```bash
swift run rdpbridge-cli caps
swift run rdpbridge-cli store-check
swift run rdpbridge-cli render-bench [seconds] [width] [height] [fps]
swift run rdpbridge-cli render-switch-check [width] [height]       # 后端切换不黑屏
swift run rdpbridge-cli render-orientation-check [width] [height]  # 画面朝向正确
swift run rdpbridge-cli retry-check <host> <user> <password>   # 重连不报「已有会话」
swift run rdpbridge-cli kit-check <host> <user> <password> [seconds] [width] [height]
swift run rdpbridge-cli <host> <user> <password> [port] [seconds] [width] [height]
```

环境变量：

- `RDP_IGNORE_CERT=1` —— 跳过证书校验（仅排障；会把证书写入 FreeRDP 信任库）
- `RDP_FINGERPRINT=<sha256>` —— 注入已确认的指纹，验证「接受后重连」

## 目录结构

```
├── Package.swift              SPM 工程定义
├── Makefile                   check / build / run / app / bench / spike / clean
├── Sources/
│   ├── Cfreerdp/              通过 pkg-config 引入 FreeRDP 的系统库模块
│   ├── RDPBridge/             C 桥接层（唯一接触 libfreerdp 的地方）
│   ├── RDPKit/                Swift 封装（配置 / 凭据存储 / 客户端 / 能力自检 / 键位映射）
│   ├── RDPRender/             渲染层（Metal / CoreGraphics 双后端 + 性能统计）
│   ├── RDPConnector/          SwiftUI 应用
│   └── RDPBridgeCLI/          开发用验证工具
├── scripts/
│   ├── validate-rdp.sh        四阶段连通性验证脚本
│   ├── build-app.sh           组装 .app bundle（默认自包含）
│   └── bundle-dylibs.sh       把第三方动态库打进 bundle 并重写 rpath
├── docs/spike-result.md       技术验证结论 + 集成踩坑记录
└── .comate/specs/             设计文档 / 任务计划 / 总结
```

## 当前范围

已实现：连接管理、内嵌渲染、键鼠输入、全屏、动态分辨率、证书 TOFU、文本剪贴板同步。

未实现：音频重定向、驱动器/打印机/USB 重定向、多显示器、RemoteApp、连接网关。
