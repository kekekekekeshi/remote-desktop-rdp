import AppKit
import RDPKit

/// 画面渲染后端。
///
/// **为什么保留 CoreGraphics 这条退路**：本机只安装了 Command Line Tools，
/// **没有 Metal 着色器编译器**（`xcrun metal` / `metallib` 随 Xcode 分发），
/// 因此 Metal 后端无法使用自定义 `.metal` 着色器。
///
/// 这决定了 Metal 后端的实现路径：上传 BGRA 纹理 → 用 `MTLBlitCommandEncoder`
/// 拷贝到 drawable。blit 不支持缩放，所以让 `drawableSize` 与远端分辨率一致，
/// 由 `CAMetalLayer` 负责放大到视图尺寸（GPU 侧完成，不占 CPU）。
///
/// 若将来安装了 Xcode，可以引入着色器做色彩空间转换、光标合成、以及
/// 「drawableSize 跟随视图像素尺寸 + 着色器缩放」以获得更锐利的显示。
public enum RDPRenderBackend: String, CaseIterable, Identifiable {
    case metal
    case coreGraphics

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .metal:        return "Metal"
        case .coreGraphics: return "CoreGraphics"
        }
    }

    /// 简述实现方式，展示在 UI 上便于理解差异
    public var detail: String {
        switch self {
        case .metal:
            return "纹理上传 + blit 拷贝到 drawable（GPU 缩放）"
        case .coreGraphics:
            return "CGImage 位图绘制（CPU 合成）"
        }
    }

    /// 创建对应的呈现器。Metal 不可用时自动回退到 CoreGraphics。
    @MainActor
    public static func makePresenter(preferred: RDPRenderBackend) -> RDPFramePresenter {
        if preferred == .metal, let presenter = MetalPresenter.make() {
            return presenter
        }
        // 没有可用的 Metal 设备（极少数情况），回退
        return CoreGraphicsPresenter()
    }
}

/// 一帧画面的呈现方式抽象。
///
/// 线程约定：全部方法只在主线程调用。
/// 调用方通过 `FrameSink` 把帧从渲染队列切到主线程后投递。
@MainActor
public protocol RDPFramePresenter: AnyObject {

    /// 实际承载画面的视图（由调用方负责布局，铺满容器）
    var view: NSView { get }

    /// 本呈现器实际使用的后端（可能与请求的不同，见回退逻辑）
    var backend: RDPRenderBackend { get }

    /// 每次**实际完成一次绘制**后回调，参数为本次绘制的 CPU 耗时（秒）。
    ///
    /// 之所以由呈现器自己上报而不是在 `present` 外层计时：两个后端的
    /// `present` 都只是标脏、真正的绘制发生在随后的 `draw(_:)` / `draw(in:)`，
    /// 在外层计时测不到实际开销。
    var onRenderCost: ((Double) -> Void)? { get set }

    /// 呈现一帧
    func present(_ frame: RDPFrame)

    /// 清空当前画面（例如断开后）
    func reset()

    /// 绘制诊断计数。
    var diagnostics: RDPRenderDiagnostics { get }

    /// 自检：回读最近一帧中指定像素的 BGRA 值。
    ///
    /// 用途是验证「上传链路真的把像素送到了渲染目标」——只看耗时无法区分
    /// 「渲染很快」和「根本没渲染」。不支持的实现返回 nil。
    func readBackPixel(x: Int, y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8)?
}

public extension RDPFramePresenter {
    func readBackPixel(x: Int, y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8)? { nil }
}

/// 绘制诊断计数。
public struct RDPRenderDiagnostics: Sendable {
    /// 完成的绘制次数（含「只清屏、无内容」的情况）
    public var drawn: Int = 0
    /// 因缺少绘制目标而跳过的次数。
    /// 非 0 通常意味着窗口未上屏（屏幕锁定、无活动显示会话等），此时性能数据不可信。
    public var skipped: Int = 0
    /// **真正画了画面内容**的次数。
    /// 与 `drawn` 的区别在于：切换后端后若只做了清屏，`drawn` 会增长但 `withContent` 不会。
    public var withContent: Int = 0

    public init(drawn: Int = 0, skipped: Int = 0, withContent: Int = 0) {
        self.drawn = drawn
        self.skipped = skipped
        self.withContent = withContent
    }
}
