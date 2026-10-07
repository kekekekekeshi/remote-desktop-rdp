import Foundation

/// 常见显示分辨率预设。
///
/// 用于配置连接时从列表里挑一个，省去手输宽高。
/// 只是**首次连接请求的分辨率**；若配置里勾选了「窗口变化时请求远端调整分辨率」，
/// 连上之后远端会跟随窗口尺寸自行调整，这里的值就不再起作用。
///
/// 按宽、高升序排列（先比宽度，同宽再比高度），便于在菜单里扫读。
public struct ResolutionPreset: Identifiable, Hashable {

    public let width: Int
    public let height: Int
    /// 通用简称（如 `FHD`）。没有广为人知叫法的分辨率为空串。
    public let name: String

    public var id: String { Self.id(width: width, height: height) }

    /// 菜单里显示的文案
    public var label: String {
        name.isEmpty ? "\(width) × \(height)" : "\(width) × \(height)  ·  \(name)"
    }

    public init(width: Int, height: Int, name: String = "") {
        self.width = width
        self.height = height
        self.name = name
    }

    public static func id(width: Int, height: Int) -> String {
        "\(width)x\(height)"
    }

    /// 内置列表（按宽、高升序）
    public static let builtIn: [ResolutionPreset] = [
        // 4:3 / 5:4
        ResolutionPreset(width: 1024, height: 768,  name: "XGA"),
        // 16:9 / 16:10
        ResolutionPreset(width: 1280, height: 720,  name: "HD"),
        ResolutionPreset(width: 1280, height: 800,  name: "WXGA"),
        ResolutionPreset(width: 1280, height: 1024, name: "SXGA"),
        ResolutionPreset(width: 1366, height: 768),
        ResolutionPreset(width: 1440, height: 900,  name: "WXGA+"),
        ResolutionPreset(width: 1600, height: 900,  name: "HD+"),
        ResolutionPreset(width: 1600, height: 1200, name: "UXGA"),
        ResolutionPreset(width: 1680, height: 1050, name: "WSXGA+"),
        ResolutionPreset(width: 1920, height: 1080, name: "FHD"),
        ResolutionPreset(width: 1920, height: 1200, name: "WUXGA"),
        // 21:9 带鱼屏
        ResolutionPreset(width: 2560, height: 1080, name: "带鱼屏 FHD"),
        ResolutionPreset(width: 2560, height: 1440, name: "QHD"),
        ResolutionPreset(width: 2560, height: 1600, name: "WQXGA"),
        ResolutionPreset(width: 3440, height: 1440, name: "带鱼屏 QHD"),
        ResolutionPreset(width: 3840, height: 1600),
        // 4K
        ResolutionPreset(width: 3840, height: 2160, name: "4K UHD"),
    ]
}
