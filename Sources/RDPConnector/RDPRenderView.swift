import AppKit
import RDPKit
import RDPRender
import SwiftUI

/// SwiftUI 包装。
///
/// 帧的投递不走 SwiftUI 的 `@Published`（见 `FrameSink`），
/// 而是直接订阅会话的帧通道，避免每帧触发 SwiftUI 视图 diff。
struct RDPRenderView: NSViewRepresentable {

    let controller: SessionController
    let backend: RDPRenderBackend
    /// 为 true 时不抢键盘焦点。会话窗口的顶部抽屉里放有可交互控件
    /// （后端选择器等），若仍无条件把 first responder 抢到渲染视图，
    /// 这些控件会在点击后立刻失焦，无法正常操作。
    var suppressFocusGrab: Bool = false

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> RDPRenderNSView {
        let view = RDPRenderNSView(backend: backend) { [weak controller] duration in
            controller?.stats.recordPresent(duration: duration)
        }

        view.onMouseMove = { [weak controller] x, y in
            controller?.sendMouseMove(x: x, y: y)
        }
        view.onMouseButton = { [weak controller] button, down, x, y in
            controller?.sendMouseButton(button, down: down, x: x, y: y)
        }
        view.onMouseWheel = { [weak controller] delta, x, y in
            controller?.sendMouseWheel(delta: delta, x: x, y: y)
        }
        view.onKey = { [weak controller] scancode, down in
            controller?.sendKey(scancode: scancode, down: down)
        }
        view.onUnicode = { [weak controller] codepoint, down in
            controller?.sendUnicode(codepoint, down: down)
        }

        context.coordinator.sink = controller.frameSink
        context.coordinator.frameToken = controller.frameSink.subscribe { [weak view] frame in
            view?.present(frame)
        }

        // 启动渲染性能统计（Metal 不可用时会回退，所以取实际生效的后端）
        controller.stats.start(backend: view.activeBackend)

        return view
    }

    func updateNSView(_ nsView: RDPRenderNSView, context: Context) {
        // Command 键的角色（Ctrl / Win）。编辑器里改完重连即生效
        nsView.cmdKeyBehavior = controller.profile.cmdKeyBehavior

        // 后端切换。这里无条件调用，由 setBackend 内部用「请求的后端」判断是否真的变了，
        // 避免因 Metal 回退导致每次更新都重建。
        if nsView.requestedBackend != backend {
            nsView.setBackend(backend)
            controller.stats.start(backend: nsView.activeBackend)
        }

        // 光标形状（变化稀疏，仅在真正改变时下发）
        if context.coordinator.lastCursor != controller.remoteCursor {
            context.coordinator.lastCursor = controller.remoteCursor
            nsView.setCursor(controller.remoteCursor)
        }

        // 服务端主动挪动光标（pointer warp）
        if let position = controller.serverCursorPosition,
           context.coordinator.lastServerPosition != position {
            context.coordinator.lastServerPosition = position
            nsView.setCursorPosition(x: Int(position.x), y: Int(position.y))
        }

        // 让渲染视图自动获得键盘焦点（抽屉被操作时让位，见 suppressFocusGrab）
        if !suppressFocusGrab {
            DispatchQueue.main.async {
                if nsView.window?.firstResponder !== nsView {
                    nsView.window?.makeFirstResponder(nsView)
                }
            }
        }
    }

    static func dismantleNSView(_ nsView: RDPRenderNSView, coordinator: Coordinator) {
        coordinator.unsubscribe()
    }

    @MainActor
    final class Coordinator {
        fileprivate var frameToken: Int?
        fileprivate weak var sink: FrameSink?
        fileprivate var lastCursor: RDPCursor?
        fileprivate var lastServerPosition: CGPoint?

        fileprivate func unsubscribe() {
            if let frameToken {
                sink?.unsubscribe(frameToken)
            }
            frameToken = nil
        }
    }
}
