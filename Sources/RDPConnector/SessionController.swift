import AppKit
import Foundation
import RDPKit
import RDPRender

/// 单个 RDP 会话的生命周期与状态。
///
/// 与 UI 的契约：
///   - `state` / `latestFrame` / `errorMessage` 全部在主线程更新
///   - 视图层只需观察这些属性，不直接接触 RDPClient
@MainActor
final class SessionController: ObservableObject {

    enum State: Equatable {
        case idle
        case connecting
        case connected
        case disconnected
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var errorMessage: String?
    @Published private(set) var remoteWidth: Int
    @Published private(set) var remoteHeight: Int

    /// 服务端证书指纹，等待用户决定是否信任（TOFU）。非 nil 时 UI 应弹窗。
    @Published var pendingFingerprint: String?

    /// 远端光标形状。形状变化非常稀疏（连接初期一两次），走 @Published 不会
    /// 造成频繁视图更新，因此不需要像画面帧那样另开通道。
    @Published private(set) var remoteCursor: RDPCursor?

    /// 服务端主动挪动光标的位置（远端像素坐标）。常规移动由渲染视图自行掌握。
    @Published private(set) var serverCursorPosition: CGPoint?

    /// 帧投递通道。画面帧刻意不走 `@Published`，避免每帧触发 SwiftUI 视图更新。
    let frameSink = FrameSink()

    /// 渲染性能统计（供后端对比）
    let stats = RenderStats()

    let profile: RDPProfile

    private let client = RDPClient()
    private let store: ProfileStore
    private let password: String

    private var pasteboardTimer: Timer?
    private var lastPasteboardChangeCount: Int

    init(profile: RDPProfile, password: String, store: ProfileStore) {
        self.profile = profile
        self.password = password
        self.store = store
        self.remoteWidth = profile.width
        self.remoteHeight = profile.height
        self.lastPasteboardChangeCount = NSPasteboard.general.changeCount

        client.onEvent = { [weak self] event in
            self?.handle(event)
        }
        client.onFrame = { [weak self] frame in
            // 由渲染队列直接投递到渲染视图（FrameSink 内部切主线程）
            self?.frameSink.publish(frame)
        }
    }

    deinit {
        pasteboardTimer?.invalidate()
    }

    // MARK: - 控制

    func start() {
        guard state != .connecting else { return }

        // 防御性清理：失败状态是在工作线程释放会话**之前**由错误事件设置的，
        // 因此用户快速点「重试」时，上一轮会话可能尚未释放。
        // disconnect() 会等待工作线程收尾，从而避免误报「已有会话在进行中」。
        client.disconnect()

        state = .connecting
        errorMessage = nil

        do {
            try client.connect(profile: profile, password: password, ignoreCertificate: false)
        } catch {
            state = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        client.disconnect()
        stopClipboardSync()
        stats.stop()
        state = .disconnected
    }

    /// 用户接受服务端证书：落盘指纹并重连
    func trustPendingCertificate() {
        guard let fingerprint = pendingFingerprint else { return }

        var updated = profile
        updated.trustedFingerprint = fingerprint
        store.update(updated)

        pendingFingerprint = nil
        start()
    }

    /// 用户拒绝服务端证书
    func rejectPendingCertificate() {
        pendingFingerprint = nil
        state = .failed("已拒绝服务端证书，连接中止")
        errorMessage = "已拒绝服务端证书，连接中止"
    }

    // MARK: - 输入转发（供渲染视图调用）

    func sendMouseMove(x: UInt16, y: UInt16) { client.sendMouseMove(x: x, y: y) }

    func sendMouseButton(_ button: Int32, down: Bool, x: UInt16, y: UInt16) {
        client.sendMouseButton(button, down: down, x: x, y: y)
    }

    func sendMouseWheel(delta: Int32, x: UInt16, y: UInt16) {
        client.sendMouseWheel(delta: delta, x: x, y: y)
    }

    func sendKey(scancode: UInt16, down: Bool) { client.sendKey(scancode: scancode, down: down) }

    func sendUnicode(_ codepoint: UInt16, down: Bool) {
        client.sendUnicode(codepoint, down: down)
    }

    func sendCtrlAltDel() { client.sendCtrlAltDel() }

    func requestResize(width: Int, height: Int) {
        client.requestResize(width: width, height: height)
    }

    /// 远端分辨率与请求分辨率不一致时（服务端不支持动态调整），返回缩放比例
    var scaleFactor: CGFloat {
        guard remoteWidth > 0, remoteHeight > 0 else { return 1 }
        return 1
    }

    // MARK: - 事件处理

    private func handle(_ event: RDPEvent) {
        switch event {
        case .connecting:
            state = .connecting

        case .connected:
            state = .connected
            errorMessage = nil
            startClipboardSync()

        case .disconnected:
            stopClipboardSync()
            if case .failed = state { break } else { state = .disconnected }

        case .error(let message):
            // 补充可操作的说明（原始 FreeRDP 文案对用户几乎没有指导意义）
            let enriched = RDPErrorHint.enrich(message)
            errorMessage = enriched
            state = .failed(enriched)

        case .certificateUntrusted(let fingerprint):
            pendingFingerprint = fingerprint
            state = .failed("服务端证书未被信任")

        case .desktopResize(let width, let height):
            remoteWidth = width
            remoteHeight = height

        case .clipboardText(let text):
            writeToPasteboard(text)

        case .cursorChanged(let cursor):
            remoteCursor = cursor

        case .cursorPosition(let x, let y):
            serverCursorPosition = CGPoint(x: x, y: y)
        }
    }

    // MARK: - 剪贴板同步

    /// 远端 → 本地：写入系统剪贴板
    private func writeToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // 记录本次写入产生的 changeCount，避免轮询把它当成用户复制而回传（防回环）
        lastPasteboardChangeCount = pasteboard.changeCount
    }

    /// 本地 → 远端：轮询系统剪贴板变化后推送
    private func startClipboardSync() {
        guard profile.clipboard else { return }

        stopClipboardSync()
        lastPasteboardChangeCount = NSPasteboard.general.changeCount

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollPasteboard()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pasteboardTimer = timer
    }

    private func stopClipboardSync() {
        pasteboardTimer?.invalidate()
        pasteboardTimer = nil
    }

    private func pollPasteboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastPasteboardChangeCount else { return }
        lastPasteboardChangeCount = pasteboard.changeCount

        // MVP 只同步纯文本
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        client.sendClipboardText(text)
    }
}
