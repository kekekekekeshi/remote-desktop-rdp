import Foundation
import RDPKit

/// 帧投递通道。
///
/// **刻意不走 SwiftUI 的 `@Published`**：画面帧是高频数据（可达 30 fps），
/// 每帧都触发 SwiftUI 视图更新会带来可观的 diff 开销，而这部分开销
/// 与渲染后端无关，会污染「Metal vs CoreGraphics」的性能对比。
///
/// 因此帧从 `RDPClient` 的渲染队列直接投递到渲染视图，只做一次主线程切换。
@MainActor
public final class FrameSink {

    public typealias Handler = (RDPFrame) -> Void

    private var handlers: [Int: Handler] = [:]
    private var nextToken = 0

    public init() {}

    /// 订阅帧。返回的 token 用于取消订阅。
    public func subscribe(_ handler: @escaping Handler) -> Int {
        nextToken += 1
        handlers[nextToken] = handler
        return nextToken
    }

    public func unsubscribe(_ token: Int) {
        handlers.removeValue(forKey: token)
    }

    /// 可从句外线程调用（`RDPClient` 的渲染队列）；内部切到主线程派发。
    public nonisolated func publish(_ frame: RDPFrame) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                for handler in self.handlers.values {
                    handler(frame)
                }
            }
        }
    }
}
