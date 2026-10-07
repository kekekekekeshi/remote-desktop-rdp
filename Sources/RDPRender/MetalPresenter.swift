import AppKit
import MetalKit
import RDPKit

/// Metal 渲染后端。
///
/// 实现路径（受限于 CLT 无着色器编译器，详见 `RDPRenderBackend` 注释）：
///   1. 把 BGRA 帧上传到 `MTLTexture`（bgra8Unorm）
///   2. 用 `MTLBlitCommandEncoder` 拷贝到 `MTKView` 的 drawable 纹理
///   3. `present(drawable)` 提交
///
/// 全程不涉及自定义着色器，也不需要 `MTLRenderPipelineState`。
///
/// 关键设置：
///   - `isPaused = true` + `enableSetNeedsDisplay = true`：按需绘制。
///     画面是事件驱动的，跑 60Hz 空转只会白耗 GPU/CPU。
///   - `autoResizeDrawable = false`：drawableSize 固定为远端分辨率，
///     由 `CAMetalLayer` 放大到视图尺寸（GPU 侧，不占 CPU）。
///   - `framebufferOnly = false`：drawable 纹理要作为 blit 目标。
///   - `layer.isOpaque = true`：忽略 BGRA 的 alpha，避免半透明异常。
@MainActor
final class MetalPresenter: NSObject, RDPFramePresenter {

    let backend: RDPRenderBackend = .metal

    var onRenderCost: ((Double) -> Void)?

    private var drawnFrames = 0
    private var skippedFrames = 0
    private var contentFrames = 0
    var diagnostics: RDPRenderDiagnostics {
        RDPRenderDiagnostics(drawn: drawnFrames, skipped: skippedFrames, withContent: contentFrames)
    }

    private let metalView: MTKView
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue

    private var texture: MTLTexture?
    private var textureSize = CGSize.zero
    private var pendingFrame: RDPFrame?

    var view: NSView { metalView }

    /// 创建呈现器。Metal 设备或命令队列不可用时返回 nil（调用方回退到 CoreGraphics）。
    static func make() -> MetalPresenter? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return nil }

        return MetalPresenter(device: device, commandQueue: queue)
    }

    private init(device: MTLDevice, commandQueue: MTLCommandQueue) {
        self.device = device
        self.commandQueue = commandQueue
        self.metalView = MTKView(frame: .zero, device: device)

        super.init()

        metalView.colorPixelFormat = .bgra8Unorm
        metalView.framebufferOnly = false
        metalView.autoResizeDrawable = false
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = true
        metalView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        metalView.layer?.isOpaque = true
        metalView.delegate = self
    }

    func present(_ frame: RDPFrame) {
        let size = CGSize(width: frame.width, height: frame.height)
        if size != textureSize {
            textureSize = size
            texture = nil                 // 尺寸变化时重建纹理
            metalView.drawableSize = size // 与远端一致，由图层负责缩放
        }

        pendingFrame = frame
        metalView.needsDisplay = true
    }

    func reset() {
        pendingFrame = nil
        texture = nil
        textureSize = .zero
        metalView.needsDisplay = true
    }

    func readBackPixel(x: Int, y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8)? {
        guard let texture,
              x >= 0, y >= 0, x < texture.width, y < texture.height
        else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.getBytes(base,
                             bytesPerRow: 4,
                             from: MTLRegionMake2D(x, y, 1, 1),
                             mipmapLevel: 0)
        }
        return (pixel[0], pixel[1], pixel[2], pixel[3])
    }

    // MARK: - 绘制

    fileprivate func drawFrame(in view: MTKView) {
        // 拿不到 drawable 时不做任何工作，也不计入耗时（否则会污染性能对比）
        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            skippedFrames += 1
            return
        }

        let started = CFAbsoluteTimeGetCurrent()
        defer {
            onRenderCost?(CFAbsoluteTimeGetCurrent() - started)
            drawnFrames += 1
        }

        guard let frame = pendingFrame,
              let texture = ensureTexture(width: frame.width, height: frame.height)
        else {
            // 无画面：只做一次清屏
            clear(drawable: drawable, commandBuffer: commandBuffer)
            return
        }

        contentFrames += 1

        // 上传像素（BGRA，行距由 FreeRDP 给出，可能大于 width*4）
        frame.pixels.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, frame.width, frame.height),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: frame.stride)
        }

        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }

        // drawableSize 已对齐远端分辨率；取 min 只是防御性处理
        let width = min(texture.width, drawable.texture.width)
        let height = min(texture.height, drawable.texture.height)

        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: drawable.texture, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func clear(drawable: CAMetalDrawable, commandBuffer: MTLCommandBuffer) {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = metalView.clearColor

        // 只清屏、不绘制，无需管线状态
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) {
            encoder.endEncoding()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func ensureTexture(width: Int, height: Int) -> MTLTexture? {
        if let texture, texture.width == width, texture.height == height {
            return texture
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: max(width, 1),
            height: max(height, 1),
            mipmapped: false)
        descriptor.usage = [.shaderRead]
        // Apple Silicon 上 .shared 是 CPU 上传的最优选择
        descriptor.storageMode = .shared

        texture = device.makeTexture(descriptor: descriptor)
        return texture
    }
}

// MARK: - MTKViewDelegate

extension MetalPresenter: MTKViewDelegate {

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // drawableSize 由本类显式控制，无需响应
    }

    nonisolated func draw(in view: MTKView) {
        // MTKView 在 enableSetNeedsDisplay 模式下于主线程回调
        MainActor.assumeIsolated {
            drawFrame(in: view)
        }
    }
}
