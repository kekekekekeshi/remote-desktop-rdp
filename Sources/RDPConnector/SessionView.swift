import AppKit
import Combine
import RDPKit
import RDPRender
import SwiftUI

/// 会话窗口：远端画面 + 状态覆盖层 + 可停靠的隐藏式控制抽屉。
///
/// 交互约定：
///   - 连接成功后**自动进入 macOS 原生全屏**（系统菜单栏随之自动隐藏）；
///     用户手动退出全屏后不会被反复弹回，但重新连接成功会再次自动全屏
///   - 不再使用窗口工具栏。控制项收进一个**可拖动的把手**：
///     光标移到把手上，抽屉从把手那一侧滑出；光标离开把手与抽屉，自动收起
///   - 把手可拖到窗口内任意位置，松手后**吸附到最近的一条边**；位置会记住
struct SessionView: View {

    @ObservedObject var controller: SessionController
    @EnvironmentObject private var model: AppModel

    /// 渲染后端选择（持久化，便于重启后保持）
    @AppStorage("renderBackend") private var backendRaw = RDPRenderBackend.coreGraphics.rawValue
    /// 把手吸附在哪条边（`HandleDockEdge.rawValue`）
    @AppStorage("handleDockEdge") private var dockEdgeRaw = HandleDockEdge.top.rawValue
    /// 把手在该边上的归一化位置，0…1
    @AppStorage("handleDockOffset") private var dockOffset = 0.5

    /// 上一次已请求过的尺寸，避免 GeometryReader 抖动造成反复请求。
    /// 用 LocalState 而非 @State，原因见 LocalState.swift。
    @StateObject private var lastRequestedSize = LocalState(CGSize.zero)

    /// 抽屉开关（关闭带延迟，见 DrawerState）
    @StateObject private var drawer = DrawerState()

    /// 承载本视图的窗口，用于进出全屏
    @StateObject private var windowHolder = WindowHolder()

    /// 当前是否全屏（决定按钮文案与图标）
    @StateObject private var isFullScreen = LocalState(false)

    /// 本次连接是否已自动进过全屏，避免用户手动退出后被反复弹回
    @StateObject private var didAutoFullScreen = LocalState(false)

    /// 拖动中的把手中心（容器坐标）。非 nil 即表示正在拖动
    @StateObject private var dragPoint = LocalState<CGPoint?>(nil)
    /// 拖动起点时的把手中心：配合 translation 使用，避免把手「跳」到手指正下方
    @StateObject private var dragAnchor = LocalState<CGPoint?>(nil)
    /// 抽屉的实测尺寸，用于把它钳在窗口内
    @StateObject private var drawerSize = LocalState(CGSize(width: 620, height: 40))

    private static let sessionSpace = "session"

    private var backend: RDPRenderBackend {
        RDPRenderBackend(rawValue: backendRaw) ?? .coreGraphics
    }

    private var dockEdge: HandleDockEdge {
        HandleDockEdge(rawValue: dockEdgeRaw) ?? .top
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                if controller.state == .connected {
                    GeometryReader { renderGeometry in
                        RDPRenderView(
                            controller: controller,
                            backend: backend,
                            // 抽屉打开时别抢键盘焦点，否则里面的控件无法操作
                            suppressFocusGrab: drawer.isOpen)
                            .onChange(of: renderGeometry.size) { _, newSize in
                                requestResizeIfNeeded(newSize)
                            }
                            .onAppear { requestResizeIfNeeded(renderGeometry.size) }
                    }
                }

                statusOverlay

                drawerLayer(container: geometry.size)
            }
            // 拖动时把手自身在动，若用局部坐标空间，translation 会被自身位移抵消；
            // 因此统一用容器坐标空间
            .coordinateSpace(.named(Self.sessionSpace))
        }
        .frame(minWidth: 640, minHeight: 420)
        .background(WindowAccessor { windowHolder.window = $0 })
        .sheet(isPresented: certificatePromptBinding) {
            CertificatePromptView(controller: controller)
        }
        .navigationTitle(controller.profile.displayName)
        .onAppear { handleStateChange(controller.state) }
        .onChange(of: controller.state) { _, newState in
            handleStateChange(newState)
        }
        .onReceive(fullScreenNotification(NSWindow.didEnterFullScreenNotification)) { _ in
            isFullScreen.value = true
        }
        .onReceive(fullScreenNotification(NSWindow.didExitFullScreenNotification)) { _ in
            isFullScreen.value = false
        }
    }

    // MARK: - 把手与抽屉

    /// 把手的实际占位尺寸。吸附在左右边时把手竖过来，长宽互换。
    private var handleFootprint: CGSize {
        HandleDockEdge.footprint(for: dockEdge)
    }

    private func drawerLayer(container: CGSize) -> some View {
        let layout = handleLayout(in: container)

        return ZStack(alignment: .topLeading) {
            if drawer.isOpen {
                drawerContent
                    .offset(x: layout.drawerOrigin.x, y: layout.drawerOrigin.y)
                    .transition(.move(edge: dockEdge.transitionEdge).combined(with: .opacity))
                    .onHover { drawer.setHovering($0) }
            }

            handleView
                .offset(x: layout.handleOrigin.x, y: layout.handleOrigin.y)
                .onHover { drawer.setHovering($0) }
                .gesture(dragGesture(container: container))
        }
        // 容器本身不绘制内容，空白处的鼠标事件仍会穿透到远端画面；
        // 只有把手与抽屉（各自带 offset）参与命中
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var handleView: some View {
        Image(systemName: handleChevron)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white.opacity(drawer.isOpen ? 0.95 : 0.6))
            .frame(width: handleFootprint.width, height: handleFootprint.height)
            .background(.black.opacity(0.5), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
            .contentShape(Capsule())
    }

    /// 收起时箭头指向「抽屉将出现的方向」，展开后反向
    private var handleChevron: String {
        switch (dockEdge, drawer.isOpen) {
        case (.top, false):    return "chevron.down"
        case (.top, true):     return "chevron.up"
        case (.bottom, false): return "chevron.up"
        case (.bottom, true):  return "chevron.down"
        case (.left, false):   return "chevron.right"
        case (.left, true):    return "chevron.left"
        case (.right, false):  return "chevron.left"
        case (.right, true):   return "chevron.right"
        }
    }

    private var drawerContent: some View {
        HStack(spacing: 10) {
            Text(statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize()

            // 渲染后端切换
            Picker("渲染后端", selection: $backendRaw) {
                ForEach(RDPRenderBackend.allCases) { candidate in
                    Text(candidate.displayName).tag(candidate.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            .disabled(controller.state != .connected)
            .help("切换渲染后端（切换会重置统计，便于对比）\n"
                  + "Metal：" + RDPRenderBackend.metal.detail + "\n"
                  + "CoreGraphics：" + RDPRenderBackend.coreGraphics.detail)

            // 性能指标
            RenderStatsBadge(stats: controller.stats)

            Divider().frame(height: 16)

            drawerButton("lock.rotation", help: "发送 Ctrl+Alt+Del") {
                controller.sendCtrlAltDel()
            }
            .disabled(controller.state != .connected)

            drawerButton(
                isFullScreen.value ? "arrow.down.right.and.arrow.up.left"
                                   : "arrow.up.left.and.arrow.down.right",
                help: isFullScreen.value ? "退出全屏" : "进入全屏"
            ) {
                setFullScreen(!isFullScreen.value)
            }
            .disabled(controller.state != .connected)

            drawerButton("xmark.circle", help: "断开并返回连接列表") {
                disconnect()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .fixedSize()
        // 实测自身尺寸，供把抽屉钳在窗口内使用
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { drawerSize.value = proxy.size }
                    .onChange(of: proxy.size) { _, newValue in drawerSize.value = newValue }
            }
            .allowsHitTesting(false))
    }

    private func drawerButton(_ systemImage: String, help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 22, height: 20)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private var statusText: String {
        switch controller.state {
        case .idle:            return "未连接"
        case .connecting:      return "连接中…"
        case .connected:       return "\(controller.remoteWidth)×\(controller.remoteHeight)"
        case .disconnected:    return "已断开"
        case .failed:          return "失败"
        }
    }

    // MARK: - 把手布局

    private struct HandleLayout {
        var handleOrigin: CGPoint
        var drawerOrigin: CGPoint
    }

    private func handleLayout(in container: CGSize) -> HandleLayout {
        let margin: CGFloat = 6
        let gap: CGFloat = 8
        let footprint = handleFootprint

        let center = dragPoint.value.map { clampToContainer($0, container) }
            ?? dockedCenter(in: container)
        let drawer = drawerSize.value

        let handleOrigin = CGPoint(x: center.x - footprint.width / 2,
                                   y: center.y - footprint.height / 2)

        // 抽屉沿把手所在的那条边滑出，主轴上贴着把手、垂直方向钳在窗口内
        switch dockEdge {
        case .top:
            return HandleLayout(
                handleOrigin: handleOrigin,
                drawerOrigin: CGPoint(
                    x: clamp(center.x - drawer.width / 2,
                             lower: margin, upper: container.width - margin - drawer.width),
                    y: handleOrigin.y + footprint.height + gap))

        case .bottom:
            return HandleLayout(
                handleOrigin: handleOrigin,
                drawerOrigin: CGPoint(
                    x: clamp(center.x - drawer.width / 2,
                             lower: margin, upper: container.width - margin - drawer.width),
                    y: handleOrigin.y - gap - drawer.height))

        case .left:
            return HandleLayout(
                handleOrigin: handleOrigin,
                drawerOrigin: CGPoint(
                    x: handleOrigin.x + footprint.width + gap,
                    y: clamp(center.y - drawer.height / 2,
                             lower: margin, upper: container.height - margin - drawer.height)))

        case .right:
            return HandleLayout(
                handleOrigin: handleOrigin,
                drawerOrigin: CGPoint(
                    x: handleOrigin.x - gap - drawer.width,
                    y: clamp(center.y - drawer.height / 2,
                             lower: margin, upper: container.height - margin - drawer.height)))
        }
    }

    /// 把手吸附在边上时的中心点
    private func dockedCenter(in container: CGSize) -> CGPoint {
        let margin: CGFloat = 6
        let footprint = handleFootprint

        func along(_ t: Double, _ extent: CGFloat, _ half: CGFloat) -> CGFloat {
            let lo = margin + half
            let hi = extent - margin - half
            guard hi > lo else { return extent / 2 }
            return lo + CGFloat(t) * (hi - lo)
        }

        switch dockEdge {
        case .top:
            return CGPoint(x: along(dockOffset, container.width, footprint.width / 2),
                           y: margin + footprint.height / 2)
        case .bottom:
            return CGPoint(x: along(dockOffset, container.width, footprint.width / 2),
                           y: container.height - margin - footprint.height / 2)
        case .left:
            return CGPoint(x: margin + footprint.width / 2,
                           y: along(dockOffset, container.height, footprint.height / 2))
        case .right:
            return CGPoint(x: container.width - margin - footprint.width / 2,
                           y: along(dockOffset, container.height, footprint.height / 2))
        }
    }

    private func clampToContainer(_ point: CGPoint, _ container: CGSize) -> CGPoint {
        let margin: CGFloat = 6
        let footprint = handleFootprint
        let minX = margin + footprint.width / 2
        let minY = margin + footprint.height / 2
        let maxX = max(minX, container.width - margin - footprint.width / 2)
        let maxY = max(minY, container.height - margin - footprint.height / 2)
        return CGPoint(x: min(max(point.x, minX), maxX),
                       y: min(max(point.y, minY), maxY))
    }

    /// 松手后吸附：取最近的一条边，并算出在该边上的归一化位置
    private func nearestEdge(for point: CGPoint,
                             in container: CGSize) -> (HandleDockEdge, Double) {
        let margin: CGFloat = 6

        func normalized(_ value: CGFloat, _ extent: CGFloat, _ half: CGFloat) -> Double {
            let lo = margin + half
            let hi = extent - margin - half
            guard hi > lo else { return 0.5 }
            return Double(min(max((value - lo) / (hi - lo), 0), 1))
        }

        let distances: [(HandleDockEdge, CGFloat)] = [
            (.top, point.y),
            (.bottom, container.height - point.y),
            (.left, point.x),
            (.right, container.width - point.x),
        ]
        let edge = distances.min { $0.1 < $1.1 }?.0 ?? .top

        switch edge {
        case .top, .bottom:
            let half = HandleDockEdge.footprint(for: edge).width / 2
            return (edge, normalized(point.x, container.width, half))
        case .left, .right:
            let half = HandleDockEdge.footprint(for: edge).height / 2
            return (edge, normalized(point.y, container.height, half))
        }
    }

    private func dragGesture(container: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.sessionSpace))
            .onChanged { value in
                if dragAnchor.value == nil {
                    dragAnchor.value = dockedCenter(in: container)
                    drawer.beginDrag()
                }
                guard let anchor = dragAnchor.value else { return }
                dragPoint.value = clampToContainer(
                    CGPoint(x: anchor.x + value.translation.width,
                            y: anchor.y + value.translation.height),
                    container)
            }
            .onEnded { value in
                // 先无条件清理拖动状态：任何提前 return 都不能把 isDragging 留在 true，
                // 否则悬停展开会永久失效
                let anchor = dragAnchor.value
                dragAnchor.value = nil
                drawer.endDrag()

                guard let anchor else {
                    dragPoint.value = nil
                    return
                }

                let released = clampToContainer(
                    CGPoint(x: anchor.x + value.translation.width,
                            y: anchor.y + value.translation.height),
                    container)
                let (edge, offset) = nearestEdge(for: released, in: container)

                // 吸附回边上的那一下做个短动画，避免生硬跳变
                withAnimation(.easeOut(duration: 0.16)) {
                    dockEdgeRaw = edge.rawValue
                    dockOffset = offset
                    dragPoint.value = nil
                }
            }
    }

    private func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, lower), max(lower, upper))
    }

    // MARK: - 全屏

    /// 连接状态变化时的全屏策略。
    ///
    /// 只在「进入 connected」时自动全屏一次；离开 connected 就复位标记，
    /// 使重新连接成功后会再次自动全屏，而用户手动退出全屏不会被打断。
    private func handleStateChange(_ state: SessionController.State) {
        if state == .connected {
            guard !didAutoFullScreen.value else { return }
            didAutoFullScreen.value = true
            setFullScreen(true)
        } else {
            didAutoFullScreen.value = false
        }
    }

    private func setFullScreen(_ wanted: Bool) {
        guard let window = windowHolder.window ?? NSApp.keyWindow else { return }
        guard window.styleMask.contains(.fullScreen) != wanted else { return }

        window.toggleFullScreen(nil)
        // 立即反馈（styleMask 要等动画结束才更新）；通知到达后会再校准一次
        isFullScreen.value = wanted
    }

    private func disconnect() {
        // 先退出全屏再结束会话，避免把连接列表留在全屏里
        setFullScreen(false)
        model.endSession()
    }

    /// 只订阅「本窗口」的全屏进出通知（sheet 等可能引入别的窗口）
    private func fullScreenNotification(
        _ name: Notification.Name
    ) -> AnyPublisher<Notification, Never> {
        NotificationCenter.default
            .publisher(for: name)
            .filter { [weak windowHolder] note in
                guard let window = note.object as? NSWindow,
                      let held = windowHolder?.window else { return false }
                return window === held
            }
            .eraseToAnyPublisher()
    }

    // MARK: - 状态覆盖层

    @ViewBuilder
    private var statusOverlay: some View {
        switch controller.state {
        case .connected:
            EmptyView()

        case .connecting, .idle:
            progress("正在连接 \(controller.profile.endpoint)…")

        case .disconnected:
            message(
                icon: "bolt.horizontal.circle",
                title: "连接已断开",
                detail: controller.errorMessage,
                actionTitle: "重新连接",
                action: { controller.start() })

        case .failed(let text):
            // 证书待确认时不叠加错误层，由 sheet 负责
            if controller.pendingFingerprint == nil {
                message(
                    icon: "exclamationmark.triangle",
                    title: "连接失败",
                    detail: text,
                    actionTitle: "重试",
                    action: { controller.start() })
            }

        }
    }

    private func progress(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(text)
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(24)
    }

    private func message(icon: String, title: String, detail: String?,
                         actionTitle: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(.orange)

            Text(title)
                .font(.headline)
                .foregroundStyle(.white)

            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .textSelection(.enabled)
            }

            HStack {
                Button("返回列表") { disconnect() }
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
    }

    // MARK: - 动态分辨率

    private func requestResizeIfNeeded(_ size: CGSize) {
        guard controller.profile.dynamicResolution, controller.state == .connected else { return }
        guard size.width >= 200, size.height >= 200 else { return }

        // 尺寸变化小于 8pt 时忽略，避免抖动
        let deltaX = abs(size.width - lastRequestedSize.value.width)
        let deltaY = abs(size.height - lastRequestedSize.value.height)
        guard lastRequestedSize.value == .zero || deltaX > 8 || deltaY > 8 else { return }

        lastRequestedSize.value = size
        controller.requestResize(width: Int(size.width), height: Int(size.height))
    }

    private var certificatePromptBinding: Binding<Bool> {
        Binding(
            get: { controller.pendingFingerprint != nil },
            set: { if !$0 { controller.rejectPendingCertificate() } })
    }
}

// MARK: - 把手停靠位置

/// 把手吸附在哪条边，决定抽屉从哪一侧滑出。
private enum HandleDockEdge: String, CaseIterable {
    case top, bottom, left, right

    /// 把手的占位尺寸：吸附在左右边时竖过来
    static func footprint(for edge: HandleDockEdge) -> CGSize {
        switch edge {
        case .top, .bottom: return CGSize(width: 78, height: 15)
        case .left, .right: return CGSize(width: 15, height: 78)
        }
    }

    /// 抽屉滑入方向
    var transitionEdge: Edge {
        switch self {
        case .top:    return .top
        case .bottom: return .bottom
        case .left:   return .leading
        case .right:  return .trailing
        }
    }
}

// MARK: - 窗口访问

/// 取到承载本视图的 `NSWindow`。
///
/// SwiftUI 没有暴露窗口的 API，而 CLT 环境下不能用 `@State`，
/// 因此用「只回传、不持有」的 `NSViewRepresentable` + 弱引用持有者。
private struct WindowAccessor: NSViewRepresentable {

    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = InertView()
        // 此时尚未加入视图层级，window 还是 nil，得等下一轮 runloop
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { onWindow(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // 已在层级中，window 可直接取到。赋值是弱引用且幂等，无需去重
        if let window = nsView.window { onWindow(window) }
    }
}

/// 永不参与命中测试的占位视图，避免背景层吞掉远端画面的鼠标事件。
private final class InertView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 弱引用持有窗口。
///
/// 用 `ObservableObject` 只是为了能放进 `@StateObject`（CLT 下没有 `@State`）；
/// 它从不发布变更，因此赋值不会触发视图更新，也不会形成
/// 「窗口 → 视图状态 → 窗口」的保留环。
private final class WindowHolder: ObservableObject {
    weak var window: NSWindow?
}

// MARK: - 抽屉状态

/// 抽屉的开关状态。
///
/// 关闭刻意带 0.25s 延迟：抽屉进出会改变自身 frame，
/// 若「一离开就关」，动画期间鼠标会瞬时落在区域外，导致反复开关抖动。
@MainActor
private final class DrawerState: ObservableObject {

    @Published var isOpen = false

    private var isDragging = false
    private var pendingClose: DispatchWorkItem?

    /// 开始拖动把手：立刻收起抽屉，并在拖动期间忽略悬停
    func beginDrag() {
        isDragging = true
        pendingClose?.cancel()
        pendingClose = nil
        guard isOpen else { return }
        withAnimation(.easeIn(duration: 0.12)) { isOpen = false }
    }

    func endDrag() {
        isDragging = false
    }

    func setHovering(_ hovering: Bool) {
        guard !isDragging else { return }

        pendingClose?.cancel()
        pendingClose = nil

        if hovering {
            guard !isOpen else { return }
            withAnimation(.easeOut(duration: 0.18)) { isOpen = true }
        } else {
            guard isOpen else { return }
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    withAnimation(.easeIn(duration: 0.18)) { self?.isOpen = false }
                }
            }
            pendingClose = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }
}
