import AppKit
import RDPKit
import SwiftUI

/// 承载远端画面并转发输入的容器视图。
///
/// 自身不绘制，只负责两件事：
///   1. 托管具体的渲染呈现器（Metal / CoreGraphics，支持运行时切换）
///   2. 输入事件的坐标换算与转发
///
/// 使用 `isFlipped = true`，使视图坐标与 RDP 的左上原点一致，
/// 免去鼠标坐标的 y 轴翻转。
@MainActor
public final class RDPRenderNSView: NSView {

    public var onMouseMove: ((UInt16, UInt16) -> Void)?
    public var onMouseButton: ((Int32, Bool, UInt16, UInt16) -> Void)?
    public var onMouseWheel: ((Int32, UInt16, UInt16) -> Void)?
    public var onKey: ((UInt16, Bool) -> Void)?
    public var onUnicode: ((UInt16, Bool) -> Void)?

    /// Command 键在远端扮演 Ctrl 还是 Win 键，见 `CmdKeyBehavior`
    public var cmdKeyBehavior: CmdKeyBehavior = .control

    /// 当前实际生效的后端（Metal 不可用时会回退，因此可能与请求的不同）
    public var activeBackend: RDPRenderBackend { presenter.backend }

    /// 上层请求的后端。
    ///
    /// 切换判断必须用它，而不是 `activeBackend`：Metal 不可用时实际后端会永久
    /// 回退到 CoreGraphics，用 `activeBackend` 判断会导致每次视图更新都重建呈现器。
    public private(set) var requestedBackend: RDPRenderBackend

    /// 绘制诊断（见 RDPRenderDiagnostics）
    public var diagnostics: RDPRenderDiagnostics { presenter.diagnostics }

    /// 自检：回读最近一帧的指定像素（见 RDPFramePresenter.readBackPixel）
    public func readBackPixel(x: Int, y: Int)
        -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8)? {
        presenter.readBackPixel(x: x, y: y)
    }

    private var presenter: RDPFramePresenter
    private var renderCostHandler: ((Double) -> Void)?
    private var remoteSize = CGSize(width: 1024, height: 768)
    private let cursorCompositor = CursorCompositor()

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func becomeFirstResponder() -> Bool { true }

    public init(backend: RDPRenderBackend, onRenderCost: ((Double) -> Void)?) {
        self.requestedBackend = backend
        self.presenter = RDPRenderBackend.makePresenter(preferred: backend)
        self.renderCostHandler = onRenderCost
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        presenter.onRenderCost = onRenderCost
        installPresenter()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RDPRenderNSView 不支持从 nib/storyboard 加载")
    }

    // MARK: - 渲染

    public func present(_ frame: RDPFrame) {
        remoteSize = CGSize(width: frame.width, height: frame.height)
        cursorCompositor.setBaseFrame(frame)
        renderCompositedFrame()
    }

    public func reset() {
        presenter.reset()
    }

    /// 更新光标形状（形状变化很稀疏）
    public func setCursor(_ cursor: RDPCursor?) {
        cursorCompositor.setCursor(cursor)
        renderCompositedFrame()
    }

    /// 更新光标热点位置（远端像素坐标）
    public func setCursorPosition(x: Int, y: Int) {
        cursorCompositor.setPosition(CGPoint(x: x, y: y))
        renderCompositedFrame()
    }

    /// 光标是否已就绪（用于诊断）
    public var isCursorReady: Bool { cursorCompositor.isCursorAvailable }

    private func renderCompositedFrame() {
        if let composited = cursorCompositor.composited() {
            presenter.present(composited)
        }
    }

    /// 切换渲染后端。
    ///
    /// 注意两点：
    ///   1. 判断依据是「请求的后端」，不是「实际生效的后端」（见 requestedBackend 说明）
    ///   2. 重建后必须**立刻用当前帧重绘**，不能只 reset ——
    ///      远端是静态画面时（如 GDM 登录页）下一帧可能很久才来，
    ///      只 reset 会让用户对着黑屏等。
    public func setBackend(_ backend: RDPRenderBackend) {
        guard backend != requestedBackend else { return }
        requestedBackend = backend

        presenter.view.removeFromSuperview()
        presenter = RDPRenderBackend.makePresenter(preferred: backend)
        presenter.onRenderCost = renderCostHandler
        installPresenter()

        // 先让新视图完成布局拿到真实尺寸（MTKView 需要非零 bounds 才能取到 drawable），
        // 再喂当前帧，避免首帧被丢弃后一直黑屏
        layoutSubtreeIfNeeded()
        renderCompositedFrame()
    }

    private func installPresenter() {
        let child = presenter.view
        child.translatesAutoresizingMaskIntoConstraints = false
        addSubview(child)

        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: leadingAnchor),
            child.trailingAnchor.constraint(equalTo: trailingAnchor),
            child.topAnchor.constraint(equalTo: topAnchor),
            child.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - 坐标换算

    /// 视图坐标 → 远端像素，并顺带同步本地光标位置。
    ///
    /// 光标位置由客户端掌握：服务端只在主动挪动光标（pointer warp）时才下发位置，
    /// 常规移动必须由客户端自己跟随，否则光标会滞后于鼠标。
    private func remotePoint(from event: NSEvent) -> (UInt16, UInt16) {
        let local = convert(event.locationInWindow, from: nil)
        let scaleX = remoteSize.width / max(bounds.width, 1)
        let scaleY = remoteSize.height / max(bounds.height, 1)

        let x = min(max(local.x * scaleX, 0), remoteSize.width - 1)
        // 远端 y 轴同样是左上原点，与 isFlipped 的视图坐标一致
        let y = min(max(local.y * scaleY, 0), remoteSize.height - 1)

        cursorCompositor.setPosition(CGPoint(x: x, y: y))

        return (UInt16(x), UInt16(y))
    }

    // MARK: - 鼠标

    public override func mouseMoved(with event: NSEvent) {
        let (x, y) = remotePoint(from: event)
        renderCompositedFrame() // 光标跟手，不必等新帧
        onMouseMove?(x, y)
    }

    public override func mouseDragged(with event: NSEvent) {
        let (x, y) = remotePoint(from: event)
        renderCompositedFrame() // 光标跟手，不必等新帧
        onMouseMove?(x, y)
    }

    public override func rightMouseDragged(with event: NSEvent) {
        let (x, y) = remotePoint(from: event)
        renderCompositedFrame() // 光标跟手，不必等新帧
        onMouseMove?(x, y)
    }

    public override func otherMouseDragged(with event: NSEvent) {
        let (x, y) = remotePoint(from: event)
        renderCompositedFrame() // 光标跟手，不必等新帧
        onMouseMove?(x, y)
    }

    public override func mouseDown(with event: NSEvent) {
        let (x, y) = remotePoint(from: event)
        onMouseButton?(RDPMouseButton.left, true, x, y)
    }

    public override func mouseUp(with event: NSEvent) {
        let (x, y) = remotePoint(from: event)
        onMouseButton?(RDPMouseButton.left, false, x, y)
    }

    public override func rightMouseDown(with event: NSEvent) {
        let (x, y) = remotePoint(from: event)
        onMouseButton?(RDPMouseButton.right, true, x, y)
    }

    public override func rightMouseUp(with event: NSEvent) {
        let (x, y) = remotePoint(from: event)
        onMouseButton?(RDPMouseButton.right, false, x, y)
    }

    public override func otherMouseDown(with event: NSEvent) {
        let (x, y) = remotePoint(from: event)
        onMouseButton?(RDPMouseButton.middle, true, x, y)
    }

    public override func otherMouseUp(with event: NSEvent) {
        let (x, y) = remotePoint(from: event)
        onMouseButton?(RDPMouseButton.middle, false, x, y)
    }

    public override func scrollWheel(with event: NSEvent) {
        let (x, y) = remotePoint(from: event)
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        onMouseWheel?(delta > 0 ? 1 : -1, x, y)
    }

    // MARK: - 键盘

    public override func keyDown(with event: NSEvent) {
        forwardKey(event, down: true)
    }

    public override func keyUp(with event: NSEvent) {
        forwardKey(event, down: false)
    }

    public override func flagsChanged(with event: NSEvent) {
        // 修饰键的按下/抬起只能从 flagsChanged 得知
        guard KeyMapping.isModifier(event.keyCode),
              let scancode = KeyMapping.scancode(forMacVirtualKeyCode: event.keyCode,
                                                 cmdBehavior: cmdKeyBehavior)
        else { return }

        onKey?(scancode, modifierIsDown(event))
    }

    private func forwardKey(_ event: NSEvent, down: Bool) {
        // 有扫描码映射的键走扫描码：保证 Ctrl/Alt 组合、功能键、方向键在远端语义正确
        if let scancode = KeyMapping.scancode(forMacVirtualKeyCode: event.keyCode,
                                              cmdBehavior: cmdKeyBehavior) {
            onKey?(scancode, down)
            return
        }

        // 其余（含 IME 输入）走 unicode 路径，规避两端键盘布局差异
        guard down, let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first,
              scalar.value < 0x10000
        else { return }

        let codepoint = UInt16(scalar.value)
        onUnicode?(codepoint, true)
        onUnicode?(codepoint, false)
    }

    private func modifierIsDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 55, 54: return event.modifierFlags.contains(.command)
        case 56, 60: return event.modifierFlags.contains(.shift)
        case 59, 62: return event.modifierFlags.contains(.control)
        case 58, 61: return event.modifierFlags.contains(.option)
        default:     return false
        }
    }
}
