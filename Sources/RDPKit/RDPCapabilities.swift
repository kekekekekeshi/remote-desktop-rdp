import Foundation
import RDPBridge

/// 底层 FreeRDP 的构建能力自检。
///
/// 为什么要做这件事：gnome-remote-desktop（GNOME 46+）强制要求客户端宣告
/// MS-RDPEGFX 且能解码 H.264。若本机安装的 FreeRDP 构建缺少这两项能力，
/// 表现为「连上了但一直黑屏」，用户很难自行判断原因。
/// 启动时检测并在缺失时明确提示，可以把这类问题前置暴露。
public struct RDPCapabilities {

    public let freerdpVersion: String
    public let buildConfig: String
    public let hasFFmpeg: Bool
    public let hasGfxH264: Bool
    public let hasVideoFFmpeg: Bool

    /// 是否满足连接 gnome-remote-desktop 的编解码要求
    public var supportsGnomeRemoteDesktop: Bool {
        hasFFmpeg && hasGfxH264
    }

    /// 缺失能力时的可读说明；能力齐备时返回 nil
    public var missingCapabilityMessage: String? {
        guard !supportsGnomeRemoteDesktop else { return nil }

        var missing: [String] = []
        if !hasGfxH264 { missing.append("WITH_GFX_H264") }
        if !hasFFmpeg { missing.append("WITH_FFMPEG") }

        return """
            当前 FreeRDP（\(freerdpVersion)）缺少 H.264/GFX 支持：\(missing.joined(separator: "、"))。
            Ubuntu 的 gnome-remote-desktop 强制要求 GFX 图形管线 + H.264，
            缺失时会出现「已连接但黑屏」。

            请安装带编解码能力的构建：
                brew reinstall freerdp
            或确认 Homebrew 版本已包含 ffmpeg 依赖：
                brew deps freerdp | grep ffmpeg
            """
    }

    public static func detect() -> RDPCapabilities {
        let version = rdp_bridge_freerdp_version().map { String(cString: $0) } ?? "unknown"
        let config = rdp_bridge_build_config().map { String(cString: $0) } ?? ""

        return RDPCapabilities(
            freerdpVersion: version,
            buildConfig: config,
            hasFFmpeg: config.contains("WITH_FFMPEG=ON"),
            hasGfxH264: config.contains("WITH_GFX_H264=ON"),
            hasVideoFFmpeg: config.contains("WITH_VIDEO_FFMPEG=ON"))
    }
}
