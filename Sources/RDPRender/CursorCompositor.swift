import AppKit
import RDPKit

/// 把远端光标合成进画面帧。
///
/// **为什么在 CPU 侧合成**：
/// Metal 后端受「无着色器」约束（CLT 没有 `xcrun metal`），
/// `MTLBlitCommandEncoder` 只能原样拷贝、无法做 alpha 混合；
/// CoreGraphics 用 `NSImage` 叠加虽然支持 alpha，但两条路径行为会不一致。
/// 统一在 CPU 侧合成后，两个后端拿到的是同一份最终像素，行为完全一致。
///
/// **效率**：只遍历光标的包围盒（通常 24×24 ~ 64×64 像素），
/// 与整帧尺寸无关；每帧一次整帧拷贝（1080p 约 8 MB，按帧率计约数十 MB/s）。
/// 线程约定：不持有共享可变状态之外的东西，但**同一个实例只能被单一线程访问**。
/// 应用里固定由渲染（主）线程使用；不加 `@MainActor` 是为了让离屏验证工具
/// 也能在后台线程复用它（`MainActor.assumeIsolated` 在非主线程会直接 trap）。
public final class CursorCompositor {

    /// 服务端原始帧（不含光标）
    private var baseFrame: RDPFrame?

    /// 当前光标形状
    private var cursor: RDPCursor?

    /// 光标热点在远端像素坐标系中的位置
    private var position = CGPoint.zero
    private var hasPosition = false

    public init() {}

    public var isCursorAvailable: Bool { cursor != nil }

    public func setBaseFrame(_ frame: RDPFrame) {
        baseFrame = frame
    }

    public func setCursor(_ cursor: RDPCursor?) {
        self.cursor = cursor
    }

    /// 设置光标热点位置（远端像素坐标）
    public func setPosition(_ point: CGPoint) {
        position = point
        hasPosition = true
    }

    /// 生成合成后的帧。没有基础帧时返回 nil；没有光标时返回原始帧。
    public func composited() -> RDPFrame? {
        guard let base = baseFrame else { return nil }

        guard let cursor, cursor.width > 0, cursor.height > 0, hasPosition else {
            return base
        }

        var pixels = base.pixels
        pixels.withUnsafeMutableBytes { raw in
            guard let dst = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            composite(cursor: cursor, into: dst,
                      frameWidth: base.width, frameHeight: base.height, stride: base.stride)
        }

        return RDPFrame(width: base.width, height: base.height,
                        stride: base.stride, pixels: pixels)
    }

    // MARK: - 合成

    private func composite(cursor: RDPCursor, into dst: UnsafeMutablePointer<UInt8>,
                           frameWidth: Int, frameHeight: Int, stride: Int) {
        // 热点对齐到远端坐标；位图左上角 = 热点位置 − 热点偏移
        let originX = Int(position.x.rounded()) - cursor.hotspotX
        let originY = Int(position.y.rounded()) - cursor.hotspotY

        cursor.pixels.withUnsafeBytes { raw in
            guard let src = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }

            for row in 0..<cursor.height {
                let y = originY + row
                guard y >= 0, y < frameHeight else { continue }

                for column in 0..<cursor.width {
                    let x = originX + column
                    guard x >= 0, x < frameWidth else { continue }

                    let source = row * cursor.width * 4 + column * 4
                    let destination = y * stride + x * 4

                    // 光标为预乘 alpha 的 BGRA，按 over 合成：dst = src + dst × (1 − a)
                    let alpha = UInt32(src[source + 3])
                    if alpha == 0 { continue }

                    if alpha == 255 {
                        dst[destination] = src[source]
                        dst[destination + 1] = src[source + 1]
                        dst[destination + 2] = src[source + 2]
                    } else {
                        let inverse = 255 - alpha
                        dst[destination] = blend(src[source], dst[destination], inverse)
                        dst[destination + 1] = blend(src[source + 1], dst[destination + 1], inverse)
                        dst[destination + 2] = blend(src[source + 2], dst[destination + 2], inverse)
                    }
                    dst[destination + 3] = 255
                }
            }
        }
    }

    private func blend(_ source: UInt8, _ destination: UInt8, _ inverseAlpha: UInt32) -> UInt8 {
        let value = UInt32(source) + UInt32(destination) * inverseAlpha / 255
        return UInt8(min(255, value))
    }
}
