import Foundation
import RDPBridge

// MARK: - 事件

/// 连接过程中上报给 UI 的事件
public enum RDPEvent {
    case connecting
    case connected
    case disconnected
    /// 可读错误描述（来自 FreeRDP 的 last_error，或桥接层自定义文案）
    case error(String)
    /// 服务端证书未被信任，需要用户决定。fingerprint 为 sha256。
    case certificateUntrusted(fingerprint: String)
    case clipboardText(String)
    case desktopResize(width: Int, height: Int)
    /// 光标形状变化（nil 表示应隐藏光标）
    case cursorChanged(RDPCursor?)
    /// 服务端主动挪动光标位置
    case cursorPosition(x: Int, y: Int)
}

// MARK: - 帧

/// 一帧远端画面。
///
/// `pixels` 为 BGRA32 像素，`stride` 是字节步长（通常 = width * 4，但可能更大）。
/// 数据已从 FreeRDP 的缓冲区拷贝出来，可安全跨线程持有。
public struct RDPFrame: Sendable {
    public let width: Int
    public let height: Int
    public let stride: Int
    public let pixels: Data

    public init(width: Int, height: Int, stride: Int, pixels: Data) {
        self.width = width
        self.height = height
        self.stride = stride
        self.pixels = pixels
    }
}

// MARK: - 鼠标按键

/// 鼠标按键标识。取值与 C 桥接层 `RDP_MOUSE_*` 一致，
/// 但以 Swift 原生常量暴露，避免 UI 层依赖 C 头文件。
public enum RDPMouseButton {
    public static let left: Int32 = 1
    public static let middle: Int32 = 2
    public static let right: Int32 = 3
}

// MARK: - 错误

public enum RDPClientError: Error, LocalizedError {
    case alreadyConnected
    case sessionCreationFailed
    case invalidProfile([String])

    public var errorDescription: String? {
        switch self {
        case .alreadyConnected:
            return "已有会话在进行中，请先断开"
        case .sessionCreationFailed:
            return "无法创建 RDP 会话（参数无效或内存不足）"
        case .invalidProfile(let issues):
            return "配置不完整：" + issues.joined(separator: "；")
        }
    }
}

// MARK: - C 回调跳板
//
// 必须是文件级函数（无捕获），才能作为 C 函数指针传给桥接层。
// 通过 user 指针把回调路由回具体的 RDPClient 实例。

private func rdpFrameTrampoline(_ bgra: UnsafePointer<UInt8>?, _ width: Int32, _ height: Int32,
                                _ stride: Int32, _ dirtyX: Int32, _ dirtyY: Int32,
                                _ dirtyW: Int32, _ dirtyH: Int32,
                                _ user: UnsafeMutableRawPointer?) {
    guard let bgra, let user else { return }
    let client = Unmanaged<RDPClient>.fromOpaque(user).takeUnretainedValue()
    client.handleFrame(bgra, width: Int(width), height: Int(height), stride: Int(stride))
}

private func rdpEventTrampoline(_ event: Int32, _ message: UnsafePointer<CChar>?,
                                _ user: UnsafeMutableRawPointer?) {
    guard let user else { return }
    let client = Unmanaged<RDPClient>.fromOpaque(user).takeUnretainedValue()
    client.handleEvent(event, message: message.map { String(cString: $0) } ?? "")
}

// MARK: - 客户端

/// RDP 会话的 Swift 门面。
///
/// 线程模型：
///   - 连接与事件循环跑在 `workerQueue`（FreeRDP 要求单线程驱动）
///   - 帧回调在 `renderQueue` 上派发（串行，避免帧乱序）
///   - 事件回调在主线程派发
///
/// 生命周期：`disconnect()` 会先请求停止、等待事件循环退出，再释放会话，
/// 确保 C 层的 user 指针在会话释放前始终有效。
public final class RDPClient {

    /// 事件回调（主线程）
    public var onEvent: ((RDPEvent) -> Void)?

    /// 帧回调（renderQueue，串行）
    public var onFrame: ((RDPFrame) -> Void)?


    private let workerQueue = DispatchQueue(label: "com.eashion.rdpconnector.worker",
                                            qos: .userInitiated)
    private let renderQueue = DispatchQueue(label: "com.eashion.rdpconnector.render",
                                            qos: .userInteractive)
    private let workerGroup = DispatchGroup()

    /// 用可重入锁：释放会话时可能经由 C 回调重入本类（见 releaseSession）
    /// 模块内可见：RDPCursor.swift 需要在同一把锁下访问会话
    let stateLock = NSRecursiveLock()
    /// 模块内可见：见 stateLock 说明
    var session: OpaquePointer?

    public init() {}

    deinit {
        disconnect()
    }

    public var isActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return session != nil
    }

    // MARK: - 连接

    /// 建立连接并开始事件循环。
    ///
    /// - Parameters:
    ///   - profile: 连接配置
    ///   - password: RDP 凭据密码（非 Linux 系统密码）
    ///   - ignoreCertificate: 跳过证书校验，**仅排障用**。
    ///     正常流程应传 false，由 `certificateUntrusted` 事件驱动 TOFU 交互。
    ///     证书的持久信任由 FreeRDP 自己维护
    ///     （`~/.config/freerdp/server/<host>_<port>.pem`），无需应用层另存。
    public func connect(profile: RDPProfile, password: String,
                        ignoreCertificate: Bool = false) throws {
        guard profile.isValid else {
            throw RDPClientError.invalidProfile(profile.validationIssues)
        }

        stateLock.lock()
        guard session == nil else {
            stateLock.unlock()
            throw RDPClientError.alreadyConnected
        }
        stateLock.unlock()

        let userPointer = Unmanaged.passUnretained(self).toOpaque()

        let created: OpaquePointer? = profile.host.withCString { host in
            profile.username.withCString { username in
                password.withCString { passwordC in
                    profile.domain.withCString { domain in
                        (profile.trustedFingerprint ?? "").withCString { fingerprint in
                            var options = RdpOptions()
                            options.host = host
                            options.port = Int32(profile.port)
                            options.username = username
                            options.password = passwordC
                            options.domain = profile.domain.isEmpty ? nil : domain
                            options.width = Int32(profile.width)
                            options.height = Int32(profile.height)
                            options.color_depth = 32
                            options.dynamic_resolution = profile.dynamicResolution
                            options.clipboard = profile.clipboard
                            options.ignore_cert = ignoreCertificate
                            options.cert_fingerprint =
                                profile.trustedFingerprint?.isEmpty == false ? fingerprint : nil

                            return rdp_session_create(&options, rdpFrameTrampoline,
                                                      rdpEventTrampoline, userPointer)
                        }
                    }
                }
            }
        }

        guard let created else {
            throw RDPClientError.sessionCreationFailed
        }

        stateLock.lock()
        session = created
        stateLock.unlock()

        workerGroup.enter()
        workerQueue.async { [weak self] in
            defer { self?.workerGroup.leave() }
            guard let self else { return }

            if rdp_session_connect(created) == 0 {
                _ = rdp_session_run(created)
            }
            // 失败时错误已由 RDP_EV_ERROR 上报，这里无需重复处理。
            //
            // 关键：无论连接失败、还是事件循环自然结束，都必须在这里释放会话。
            // 否则 session 一直非 nil，之后任何重连都会被误判成
            // 「已有会话在进行中」——表现为「重新连接 / 重试」按钮永久失效。
            self.releaseSession(created)
        }
    }

    /// 断开会话。可安全重复调用。
    ///
    /// 会阻塞等待事件循环退出并完成资源释放（通常数十毫秒，最长约数百毫秒）。
    public func disconnect() {
        stateLock.lock()
        let current = session
        stateLock.unlock()

        guard let current else { return }

        // 只置停止标志；实际 freerdp_disconnect 由事件循环线程执行
        rdp_session_disconnect(current)

        // 等待工作线程释放会话（见 releaseSession）
        workerGroup.wait()
    }

    // MARK: - 会话所有权
    //
    // 会话由**工作线程**持有并负责释放。这里用同一把锁覆盖
    // 「读指针 → 调用 C」的整个过程，保证释放不会与输入调用并发，
    // 也不会出现「读到的指针刚被释放」的窗口。

    /// 在持锁状态下访问会话；会话不存在时返回 nil
    @discardableResult
    private func withSession<T>(_ body: (OpaquePointer) -> T) -> T? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let session else { return nil }
        return body(session)
    }

    /// 释放会话（幂等）。由工作线程在 connect/run 结束后调用。
    private func releaseSession(_ target: OpaquePointer) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard session == target else { return }
        session = nil
        rdp_session_free(target)
    }

    /// 仅用于诊断
    func currentSession() -> OpaquePointer? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return session
    }

    // MARK: - 输入（供 UI 调用）

    public func sendMouseMove(x: UInt16, y: UInt16) {
        withSession { rdp_send_mouse_move($0, x, y) }
    }

    public func sendMouseButton(_ button: Int32, down: Bool, x: UInt16, y: UInt16) {
        withSession { rdp_send_mouse_button($0, button, down, x, y) }
    }

    public func sendMouseWheel(delta: Int32, x: UInt16, y: UInt16) {
        withSession { rdp_send_mouse_wheel($0, delta, x, y) }
    }

    public func sendKey(scancode: UInt16, down: Bool) {
        withSession { rdp_send_key_scancode($0, scancode, down) }
    }

    public func sendUnicode(_ codepoint: UInt16, down: Bool) {
        withSession { rdp_send_unicode_char($0, codepoint, down) }
    }

    public func sendCtrlAltDel() {
        withSession { rdp_send_ctrl_alt_del($0) }
    }

    public func requestResize(width: Int, height: Int) {
        withSession { rdp_request_resize($0, Int32(width), Int32(height)) }
    }

    /// 把本地剪贴板文本推给远端（宣告 + 按需回应内容请求）
    public func sendClipboardText(_ text: String) {
        withSession { session in
            text.withCString { rdp_send_clipboard_text(session, $0) }
        }
    }

    // MARK: - 回调处理（由 C 跳板调用）

    fileprivate func handleFrame(_ buffer: UnsafePointer<UInt8>,
                                 width: Int, height: Int, stride: Int) {
        let byteCount = stride * height
        // 立即拷贝：FreeRDP 的缓冲区在回调返回后即失效
        let pixels = Data(bytes: buffer, count: byteCount)
        let frame = RDPFrame(width: width, height: height, stride: stride, pixels: pixels)

        renderQueue.async { [weak self] in
            self?.onFrame?(frame)
        }
    }

    fileprivate func handleEvent(_ rawEvent: Int32, message: String) {
        let event: RDPEvent

        // 匿名 C 枚举常量在 Swift 中导入为 Int
        switch Int(rawEvent) {
        case RDP_EV_CONNECTING:
            event = .connecting
        case RDP_EV_CONNECTED:
            event = .connected
        case RDP_EV_DISCONNECTED:
            event = .disconnected
        case RDP_EV_ERROR:
            event = .error(message)
        case RDP_EV_CERT_UNTRUSTED:
            event = .certificateUntrusted(fingerprint: message)
        case RDP_EV_CLIPBOARD_TEXT:
            event = .clipboardText(message)
        case RDP_EV_CURSOR_UPDATE:
            // 形状变化频率很低（连接初期一两次），取副本后随事件回主线程
            event = .cursorChanged(fetchCursor())
        case RDP_EV_CURSOR_POSITION:
            let parts = message.split(separator: ",")
            guard parts.count == 2, let x = Int(parts[0]), let y = Int(parts[1]) else { return }
            event = .cursorPosition(x: x, y: y)
        case RDP_EV_DESKTOP_RESIZE:
            let parts = message.split(separator: "x")
            if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) {
                event = .desktopResize(width: w, height: h)
            } else {
                return
            }
        default:
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event)
        }
    }
}
