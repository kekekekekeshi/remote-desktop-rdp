import AppKit
import RDPKit

/// CoreGraphics 渲染后端：把 BGRA 帧包成 `NSImage`，在 `draw(_:)` 里绘制。
///
/// 优点：实现简单、无额外依赖、缩放与色彩空间由 AppKit 处理。
/// 代价：每帧都要新建 `CGImage` / `NSImage`，且合成走 CPU 路径。
///
/// **性能测量口径**：`NSView.draw(_:)` 只是把绘制命令记录进窗口后备存储，
/// 真正的光栅化发生在随后的 flush，不在本方法内。若只统计 `draw`，
/// 会严重低估本后端的开销。因此这里把一帧的完整成本定义为
/// 「构造 `NSImage`（在 `present` 中）+ `draw` 调用」，合并上报一次，
/// 以便与 Metal 的「同步上传 + 编码」口径对齐。
final class CoreGraphicsPresenter: NSObject, RDPFramePresenter {

    let backend: RDPRenderBackend = .coreGraphics

    var onRenderCost: ((Double) -> Void)?

    private var drawnFrames = 0
    private var contentFrames = 0
    private var pendingImageCost: Double = 0

    var diagnostics: RDPRenderDiagnostics {
        RDPRenderDiagnostics(drawn: drawnFrames, skipped: 0, withContent: contentFrames)
    }

    private let renderView = CanvasView()

    var view: NSView { renderView }

    override init() {
        super.init()

        renderView.onDraw = { [weak self] drawCost, hadContent in
            guard let self else { return }
            // 一帧的完整 CPU 成本 = 构造位图 + 绘制
            let total = self.pendingImageCost + drawCost
            self.pendingImageCost = 0
            self.drawnFrames += 1
            if hadContent { self.contentFrames += 1 }
            self.onRenderCost?(total)
        }
    }

    func present(_ frame: RDPFrame) {
        let started = CFAbsoluteTimeGetCurrent()
        let image = Self.makeImage(from: frame)
        pendingImageCost = CFAbsoluteTimeGetCurrent() - started

        renderView.apply(image: image)
    }

    func reset() {
        pendingImageCost = 0
        renderView.apply(image: nil)
    }

    private static func makeImage(from frame: RDPFrame) -> NSImage? {
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)

        guard let provider = CGDataProvider(data: frame.pixels as CFData),
              let cgImage = CGImage(
                width: frame.width,
                height: frame.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: frame.stride,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent)
        else { return nil }

        return NSImage(cgImage: cgImage,
                       size: NSSize(width: frame.width, height: frame.height))
    }

    /// 实际的绘制视图
    private final class CanvasView: NSView {

        var onDraw: ((Double, Bool) -> Void)?

        private var cachedImage: NSImage?

        override var isFlipped: Bool { true }

        func apply(image: NSImage?) {
            cachedImage = image
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            let started = CFAbsoluteTimeGetCurrent()
            defer { onDraw?(CFAbsoluteTimeGetCurrent() - started, cachedImage != nil) }

            guard let context = NSGraphicsContext.current?.cgContext else { return }

            // 未收到画面时铺黑底，避免残影
            context.setFillColor(NSColor.black.cgColor)
            context.fill(bounds)

            guard let image = cachedImage, bounds.width > 0, bounds.height > 0 else { return }

            /*
             * 视图是 isFlipped（y 轴向下，与 RDP 的左上原点一致），
             * 但 CoreGraphics 绘制位图时按 y 轴向上解释 ——
             * 直接在翻转上下文里画会**上下颠倒**。
             *
             * 实测（构造「上红下蓝」的图，渲染后读回像素）：
             *   直接画         → 上方=蓝、下方=红  （颠倒）
             *   加下面的翻转   → 上方=红、下方=蓝  （正确）
             *
             * 这里把坐标系翻回 y 轴向上再画，画完恢复。
             */
            context.saveGState()
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            image.draw(in: CGRect(origin: .zero, size: bounds.size),
                       from: .zero, operation: .copy, fraction: 1.0)
            context.restoreGState()
        }
    }
}
