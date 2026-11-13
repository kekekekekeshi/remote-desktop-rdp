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
    /// 滚轮：(格数, 是否横向, x, y)。格数为正表示向上 / 向右。
    public var onMouseWheel: ((Int32, Bool, UInt16, UInt16) -> Void)?
    public var onKey: ((UInt16, Bool) -> Void)?
    public var onUnicode: ((UInt16, Bool) -> Void)?

    /// 修饰键映射（Cmd 当 Ctrl / Win，或互换）。见 `CmdKeyBehavior`
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

    /// macOS「编辑」菜单占用的快捷键所对应的键（见 `handleEditingShortcut`）
    private static let editingShortcutKeys: Set<String> = ["a", "c", "v", "x", "z", "y"]

    /// 本地事件监听句柄（`.keyDown` 在分发前拦下被菜单吃掉的组合）
    private var shortcutMonitor: Any?

    /// 窗口失焦通知（用于补发修饰键抬起）
    private var resignKeyObserver: NSObjectProtocol?

    /// 键位日志开关：环境变量 `RDP_KEYLOG` 存在即开启
    private static let keyLogEnabled = ProcessInfo.processInfo.environment["RDP_KEYLOG"] != nil

    /// `RDP_KEYLOG` 的值不是 `1` 时当作文件路径，日志直接追加写入（GUI 启动也方便看）
    private static let keyLogFile: String? = {
        guard let value = ProcessInfo.processInfo.environment["RDP_KEYLOG"],
              !value.isEmpty, value != "1"
        else { return nil }
        return value
    }()

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

    /// 光标重绘合并。
    ///
    /// `mouseMoved` 一旦真的送达就是连续高频事件，而 `composited()` 每次都要复制
    /// 整帧（1080p 约 8 MB）再呈现。这里把同一轮 runloop 内的多次移动合并成一次
    /// 重绘：合成用的始终是光标合成器里的最新位置，观感不变。
    /// 输入事件本身仍然逐条即时下发，不受影响。
    private var cursorRedrawScheduled = false

    private func scheduleCursorRedraw() {
        guard !cursorRedrawScheduled else { return }
        cursorRedrawScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            cursorRedrawScheduled = false
            renderCompositedFrame()
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

    /// 覆盖整个视图的鼠标跟踪区域：让 `mouseMoved` 在没有按键时也持续送达。
    ///
    /// NSView 默认收不到 NSMouseMoved：那条通路要求 `window.acceptsMouseMovedEvents`
    /// 且视图是 first responder。本视图两者都靠不住——SwiftUI 宿主窗口不会打开该开关，
    /// 而抽屉被操作时还会主动让出焦点（见 `RDPRenderView.suppressFocusGrab`）。
    /// 跟踪区域是按视图生效的，两者都不依赖，远端的 hover（链接高亮、悬停菜单）
    /// 因此无需先点一下就能跟手。
    private var hoverTrackingArea: NSTrackingArea?

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    public override func mouseMoved(with event: NSEvent) {
        let (x, y) = remotePoint(from: event)
        scheduleCursorRedraw() // 光标跟手，不必等新帧
        onMouseMove?(x, y)
    }

    public override func mouseDragged(with event: NSEvent) {
        let (x, y) = remotePoint(from: event)
        scheduleCursorRedraw() // 光标跟手，不必等新帧
        onMouseMove?(x, y)
    }

    public override func rightMouseDragged(with event: NSEvent) {
        let (x, y) = remotePoint(from: event)
        scheduleCursorRedraw() // 光标跟手，不必等新帧
        onMouseMove?(x, y)
    }

    public override func otherMouseDragged(with event: NSEvent) {
        let (x, y) = remotePoint(from: event)
        scheduleCursorRedraw() // 光标跟手，不必等新帧
        onMouseMove?(x, y)
    }

    public override func mouseDown(with event: NSEvent) {
        // 点画面即取回键盘焦点：焦点被抽屉控件等拿走时键盘会整块失效
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
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

    // MARK: - 滚轮 / 触摸板滚动

    /// 触摸板的精确增量攒够多少像素算「一格」。
    ///
    /// RDP 只有整格的滚轮事件（一格 = 120 单位），而触摸板一次事件往往只有
    /// 1~3 px。一个事件发一格会让远端滚动速度失控（快一个数量级），
    /// 所以两轴都要攒够阈值再发。30 px/格大致对齐本地触摸板手感：
    /// 远端滚得太快就调大，跟不上手就调小。
    private static let pixelsPerWheelNotch: CGFloat = 30

    /// 两轴各自「未满一格」的余量，用于跨事件累积
    private var scrollRemainderX: CGFloat = 0
    private var scrollRemainderY: CGFloat = 0

    /// 两指滚动：两条轴都要转发。
    ///
    /// 只看 `scrollingDeltaY` 会让左右两指滑动彻底消失（RDP 侧靠
    /// PTR_FLAGS_HWHEEL 区分横向，见 rdp_send_mouse_wheel）。
    /// 对角线滚动两条轴各发各的，与本地行为一致。
    public override func scrollWheel(with event: NSEvent) {
        let (x, y) = remotePoint(from: event)
        forwardScroll(event.scrollingDeltaX, horizontal: true, x: x, y: y, event: event)
        forwardScroll(event.scrollingDeltaY, horizontal: false, x: x, y: y, event: event)
    }

    private func forwardScroll(_ delta: CGFloat, horizontal: Bool, x: UInt16, y: UInt16,
                               event: NSEvent) {
        var remainder = horizontal ? scrollRemainderX : scrollRemainderY

        // 硬件滚轮：事件本身就是整格（hasPreciseScrollingDeltas == false），不参与累积
        if delta != 0, !event.hasPreciseScrollingDeltas {
            setRemainder(0, horizontal: horizontal)
            onMouseWheel?(delta > 0 ? 1 : -1, horizontal, x, y)
            return
        }

        if delta != 0 {
            // 换向（或新手势开始）时丢掉旧余量：反向的零头相互抵消会表现为「纹丝不动」
            if event.phase == .mayBegin || (remainder > 0) != (delta > 0) {
                remainder = 0
            }
            remainder += delta
            let notches = Int(remainder / Self.pixelsPerWheelNotch)  // 向零截断，符号即方向
            remainder -= CGFloat(notches) * Self.pixelsPerWheelNotch
            if notches != 0 {
                onMouseWheel?(Int32(notches), horizontal, x, y)
            }
        }

        // 惯性收尾 / 取消：补发不足一格的零头，否则最后一段滚动会被吞掉
        let gestureEnds = event.phase == .ended || event.phase == .cancelled
            || event.momentumPhase == .ended || event.momentumPhase == .cancelled
        if gestureEnds {
            if abs(remainder) >= Self.pixelsPerWheelNotch / 2 {
                onMouseWheel?(remainder > 0 ? 1 : -1, horizontal, x, y)
            }
            remainder = 0
        }
        setRemainder(remainder, horizontal: horizontal)
    }

    private func setRemainder(_ value: CGFloat, horizontal: Bool) {
        if horizontal { scrollRemainderX = value } else { scrollRemainderY = value }
    }

    // MARK: - 键盘

    /// 本地修饰键。用它记录「已向远端下发按下」的状态，保证 down/up 成对。
    private enum LocalModifier {
        case command, shift, control, option

        init?(keyCode: UInt16) {
            switch keyCode {
            case 55, 54: self = .command
            case 56, 60: self = .shift
            case 59, 62: self = .control
            case 58, 61: self = .option
            default: return nil
            }
        }

        func isDown(in flags: NSEvent.ModifierFlags) -> Bool {
            switch self {
            case .command: return flags.contains(.command)
            case .shift: return flags.contains(.shift)
            case .control: return flags.contains(.control)
            case .option: return flags.contains(.option)
            }
        }
    }

    /// 已下发「按下」但尚未抬起的修饰键 → 实际下发的扫描码。
    ///
    /// 记录扫描码而不是重算：Cmd 的映射可能随设置变化，抬起时必须用**当初按下**的那个码，
    /// 否则远端会卡着一个永不释放的修饰键。
    private var sentModifiers: [LocalModifier: UInt16] = [:]

    public override func keyDown(with event: NSEvent) {
        forwardKey(event, down: true)
    }

    public override func keyUp(with event: NSEvent) {
        forwardKey(event, down: false)
    }

    public override func flagsChanged(with event: NSEvent) {
        // 修饰键的按下/抬起只能从 flagsChanged 得知
        guard let modifier = LocalModifier(keyCode: event.keyCode),
              let scancode = KeyMapping.scancode(forMacVirtualKeyCode: event.keyCode,
                                                 cmdBehavior: cmdKeyBehavior)
        else { return }

        logKey(event, note: "flagsChanged")

        if modifier.isDown(in: event.modifierFlags) {
            // 去重：重复的 down 会让远端把它当「按住不放」
            guard sentModifiers[modifier] == nil else { return }
            sentModifiers[modifier] = scancode
            onKey?(scancode, true)
        } else {
            // 用实际下发过的扫描码回抬
            guard let sent = sentModifiers.removeValue(forKey: modifier) else { return }
            onKey?(sent, false)
        }
    }

    /// 自愈：本地物理键已经抬起、但我们仍认为远端按着时，补发抬起。
    ///
    /// macOS 在应用失焦（⌘Tab、点别的窗口、抽屉抢焦点）时**不会**补发 flagsChanged，
    /// 于是远端会永久卡住 Ctrl —— 表现是此后每个按键都变成 `Ctrl+某键`，
    /// 看起来就是「键盘完全失灵」，而且点画面、点按钮都救不回来，只有重连才恢复。
    private func reconcileModifiers(with flags: NSEvent.ModifierFlags) {
        guard !sentModifiers.isEmpty else { return }
        for (modifier, scancode) in sentModifiers where !modifier.isDown(in: flags) {
            logRelease(modifier, scancode)
            onKey?(scancode, false)
            sentModifiers[modifier] = nil
        }
    }

    /// 释放所有已下发的修饰键（失焦 / 离开窗口时调用）
    private func releaseAllModifiers() {
        guard !sentModifiers.isEmpty else { return }
        for (modifier, scancode) in sentModifiers {
            logRelease(modifier, scancode)
            onKey?(scancode, false)
        }
        sentModifiers.removeAll()
    }

    private func logRelease(_ modifier: LocalModifier, _ scancode: UInt16) {
        guard Self.keyLogEnabled else { return }
        appendKeyLog(String(format: "补发修饰键抬起 scancode=0x%04X (%@)",
                            scancode, String(describing: modifier)))
    }

    /// 统一的日志出口：系统日志 + 可选文件
    private func appendKeyLog(_ line: String) {
        NSLog("[RDPKey] %@", line)

        guard let path = Self.keyLogFile else { return }
        let text = "[RDPKey] \(line)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            handle.closeFile()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    public override func resignFirstResponder() -> Bool {
        releaseAllModifiers()
        return super.resignFirstResponder()
    }

    // MARK: - 被 macOS 编辑菜单吃掉的组合键

    /// macOS 应用自带「编辑」菜单，其中 Cut / Copy / Paste 持有 ⌘X / ⌘C / ⌘V 的快捷键，
    /// 这些事件在到达视图之前就被菜单当 key equivalent 处理掉了 —— 远端收到的就是
    /// 「什么都没发生」。而 ⌘A（Select All）恰好没被菜单占用，能正常落到 `keyDown`，
    /// 于是现象很反直觉：**能全选，不能复制粘贴**。
    ///
    /// 这里用本地事件监听在分发之前把这些组合拦下来，按当前修饰键映射转成远端按键。
    /// 只拦 keyDown，keyUp 仍走正常通道，因此不会漏发 release。
    private func handleEditingShortcut(_ event: NSEvent) -> Bool {
        // 只在渲染视图持有键盘焦点时接管，否则会抢掉应用自己文本框的复制粘贴
        guard window?.isKeyWindow == true, window?.firstResponder === self else { return false }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ⌃⌘ / ⌥⌘ 组合留给 macOS（如全屏 ⌃⌘F），只接管纯 Cmd（可带 Shift）的组合
        guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option) else {
            return false
        }
        guard let key = event.charactersIgnoringModifiers?.lowercased(),
              Self.editingShortcutKeys.contains(key)
        else { return false }

        // 这里必须自己补齐「抬起」：本地监听返回 nil 后，AppKit **不会**再投递这个键的
        // keyUp（实测确认，见 `make key-check`）。只发按下不发抬起，远端会把这个键
        // 永久当成按住状态 —— 表现为此后键盘整体失灵、点画面无效、只能重连。
        forwardKey(event, down: true)
        forwardKey(event, down: false)
        return true
    }

    private func installShortcutMonitor() {
        guard shortcutMonitor == nil else { return }
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleEditingShortcut(event) ?? false }
            return handled ? nil : event
        }
    }

    private func removeShortcutMonitor() {
        if let shortcutMonitor {
            NSEvent.removeMonitor(shortcutMonitor)
            self.shortcutMonitor = nil
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if let observer = resignKeyObserver {
            NotificationCenter.default.removeObserver(observer)
            resignKeyObserver = nil
        }

        guard let window else {
            removeShortcutMonitor()
            releaseAllModifiers()
            return
        }

        installShortcutMonitor()

        // 窗口失去 key 状态（切到别的应用）时，按住的修饰键抬起事件不会再送达，
        // 必须主动补发，否则远端会卡着 Ctrl —— 见 reconcileModifiers
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseAllModifiers() }
        }
    }

    deinit {
        if let shortcutMonitor {
            NSEvent.removeMonitor(shortcutMonitor)
        }
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
        }
    }

    private func forwardKey(_ event: NSEvent, down: Bool) {
        logKey(event, note: down ? "keyDown" : "keyUp")
        reconcileModifiers(with: event.modifierFlags)

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

    /// 键位日志：`RDP_KEYLOG=1` 打系统日志（`log stream`），
    /// `RDP_KEYLOG=/tmp/rdpkey.log` 直接追加写文件（GUI 双击启动也能用）。
    ///
    /// 排查「某个组合键在远端没反应」时能立刻区分三种情况：
    /// 事件没到视图（无日志）/ 映射不对（scancode 不符）/ 下发了但远端不响应。
    private func logKey(_ event: NSEvent, note: String) {
        guard Self.keyLogEnabled else { return }
        let scancode = KeyMapping.scancode(forMacVirtualKeyCode: event.keyCode,
                                           cmdBehavior: cmdKeyBehavior)
        appendKeyLog(String(format: "%@ keyCode=%d scancode=%@ flags=0x%llx behavior=%@",
                            note,
                            Int(event.keyCode),
                            scancode.map { String(format: "0x%04X", $0) } ?? "nil",
                            event.modifierFlags.rawValue,
                            cmdKeyBehavior.rawValue))
    }
}
