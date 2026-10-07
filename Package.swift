// swift-tools-version: 6.2
// macOS RDP 连接器 —— SPM 工程定义
//
// 分层：
//   Cfreerdp    (systemLibrary) 通过 pkg-config 引入 Homebrew 的 FreeRDP 3.x
//   RDPBridge   (C)             唯一接触 libfreerdp 的地方，暴露朴素 C ABI
//   RDPKit      (Swift)         封装 C 桥接，提供 Swift 友好的 API
//   RDPConnector(executable)    SwiftUI 应用

import PackageDescription

let package = Package(
    name: "RDPConnector",
    // 部署目标跟随 Homebrew 版 FreeRDP 的构建目标（macOS 26），避免链接期版本不匹配。
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "RDPConnector", targets: ["RDPConnector"]),
        // 开发用验证工具：不经 GUI 直接驱动 C 桥接层，用于验证各层实现
        .executable(name: "rdpbridge-cli", targets: ["RDPBridgeCLI"])
    ],
    targets: [
        // 通过 pkg-config 引入 FreeRDP（brew install freerdp）
        // 用 freerdp-client3 而非 freerdp3：桥接层需要 freerdp_client_load_addins
        // 来加载静态/动态通道插件（drdynvc / rdpgfx 等），GFX 协商依赖它。
        .systemLibrary(
            name: "Cfreerdp",
            path: "Sources/Cfreerdp",
            pkgConfig: "freerdp-client3",
            providers: [.brew(["freerdp"])]
        ),

        // C 桥接层：会话生命周期 / settings / 事件循环 / 帧回调 / 输入注入
        .target(
            name: "RDPBridge",
            dependencies: ["Cfreerdp"],
            path: "Sources/RDPBridge",
            publicHeadersPath: "include",
            cSettings: [
                // FreeRDP 3.x 头文件内部大量使用自身已弃用的声明，会污染构建输出。
                // 这里只针对桥接层关闭该告警，不影响我们自己的代码质量检查。
                .unsafeFlags(["-Wno-deprecated-declarations"])
            ]
        ),

        // Swift 封装层
        .target(
            name: "RDPKit",
            dependencies: ["RDPBridge"],
            path: "Sources/RDPKit"
        ),

        // 画面渲染层：可切换 Metal / CoreGraphics 后端 + 性能统计
        // 独立成库是为了能被 RDPConnector 与开发用基准测试工具共用
        .target(
            name: "RDPRender",
            dependencies: ["RDPKit"],
            path: "Sources/RDPRender"
        ),

        // SwiftUI 应用
        .executableTarget(
            name: "RDPConnector",
            dependencies: ["RDPKit", "RDPRender"],
            path: "Sources/RDPConnector"
        ),

        // 开发用验证工具（非交付物）：直接驱动 C 桥接层与各封装层
        .executableTarget(
            name: "RDPBridgeCLI",
            dependencies: ["RDPBridge", "RDPKit", "RDPRender"],
            path: "Sources/RDPBridgeCLI"
        )
    ],
    // 本工程大量使用 C 回调与跨线程帧投递，Swift 5 语言模式更贴合；
    // 严格并发检查会与 FreeRDP 的单线程事件循环模型冲突。
    swiftLanguageModes: [.v5]
)
