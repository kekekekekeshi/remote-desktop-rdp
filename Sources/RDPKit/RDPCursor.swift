import Foundation
import RDPBridge

/// 远端光标形状。
///
/// RDP 的分工：**服务端只下发光标形状，位置与绘制由客户端负责**。
/// 位置之所以由客户端掌握，是因为绝大多数移动都源自客户端自己的鼠标输入；
/// 服务端只在自己主动挪动光标（pointer warp）时下发位置事件。
///
/// `pixels` 为 BGRA32、**预乘 alpha**，长度 `width * height * 4`。
public struct RDPCursor: Sendable, Equatable {

    public let width: Int
    public let height: Int
    public let hotspotX: Int
    public let hotspotY: Int
    public let pixels: Data

    public init(width: Int, height: Int, hotspotX: Int, hotspotY: Int, pixels: Data) {
        self.width = width
        self.height = height
        self.hotspotX = hotspotX
        self.hotspotY = hotspotY
        self.pixels = pixels
    }
}

extension RDPClient {

    /// 从桥接层取当前光标形状的副本。无光标时返回 nil。
    ///
    /// 该方法在 FreeRDP 的工作线程上被调用，与 `releaseSession` 同线程，
    /// 因此可以直接持锁访问会话指针。
    func fetchCursor() -> RDPCursor? {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard let session else { return nil }

        var info = RdpCursorInfo()
        // 没有位图：可能是「隐藏光标」或尚未收到形状，两种情况都不渲染
        guard let raw = rdp_session_copy_cursor(session, &info) else { return nil }
        defer { free(raw) }

        let width = Int(info.width)
        let height = Int(info.height)
        guard width > 0, height > 0 else { return nil }

        let pixels = Data(bytes: raw, count: width * 4 * height)
        return RDPCursor(width: width, height: height,
                         hotspotX: Int(info.hotspot_x), hotspotY: Int(info.hotspot_y),
                         pixels: pixels)
    }
}
