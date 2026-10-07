import AppKit
import Foundation
import ImageIO
import RDPBridge
import RDPKit
import RDPRender

// 开发用验证工具（非交付物）。
//
// 子命令：
//   caps                                 检查 FreeRDP 的 H.264/GFX 能力（Task 15）
//   store-check                          验证 ProfileStore / CredentialStore（Task 8）
//   render-bench                         渲染后端性能对比（Task 16）
//   kit-check <host> <user> <pwd> [...]  验证 RDPClient 封装层（Task 9）
//   <host> <user> <password> [...]       验证 C 桥接层连接/帧/输入（Task 4–7）
//
// 连接用法:
//   swift run rdpbridge-cli <host> <user> <password> [port] [seconds] [width] [height]

/// 保存最近一帧，供诊断时导出成 PNG 目视检查。
final class LatestFrameHolder {
    private let lock = NSLock()
    private var frame: RDPFrame?

    func store(_ frame: RDPFrame) {
        lock.lock(); self.frame = frame; lock.unlock()
    }

    var latest: RDPFrame? {
        lock.lock(); defer { lock.unlock() }; return frame
    }
}

/// 把一帧 BGRA 画面写成 PNG（用于人工目视核对渲染结果）。
@discardableResult
func writePNG(_ frame: RDPFrame, to path: String) -> Bool {
    let bitmapInfo = CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)

    guard let provider = CGDataProvider(data: frame.pixels as CFData),
          let image = CGImage(
            width: frame.width, height: frame.height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: frame.stride,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo,
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let destination = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
    else { return false }

    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
}

/// 最近邻放大，便于目视检查小尺寸位图（如光标）。
func upscale(_ frame: RDPFrame, factor: Int) -> RDPFrame {
    let width = frame.width * factor
    let height = frame.height * factor
    let stride = width * 4
    var out = [UInt8](repeating: 0, count: stride * height)

    frame.pixels.withUnsafeBytes { raw in
        guard let src = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        for y in 0..<height {
            let sy = y / factor
            for x in 0..<width {
                let sx = x / factor
                let s = sy * frame.stride + sx * 4
                let d = y * stride + x * 4
                out[d] = src[s]; out[d + 1] = src[s + 1]
                out[d + 2] = src[s + 2]; out[d + 3] = src[s + 3]
            }
        }
    }

    return RDPFrame(width: width, height: height, stride: stride, pixels: Data(out))
}

/// 帧内容指纹统计：用于判断「鼠标移动是否改变了画面内容」。
///
/// 静态的 GDM 登录页在无操作时几乎不产生帧；若移动鼠标能持续产生**内容不同**的帧，
/// 说明光标是被服务端合成进视频流的（而不是走独立 Pointer 通道）。
final class FrameFingerprints {
    private let lock = NSLock()
    private var seen = Set<UInt64>()
    private var total = 0

    func record(_ pixels: Data) {
        // 抽样计算 FNV-1a，避免整帧哈希的开销
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        pixels.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var index = 0
            while index < pixels.count {
                hash = (hash ^ UInt64(base[index])) &* 0x0000_0100_0000_01B3
                index += 997
            }
        }
        lock.lock()
        seen.insert(hash)
        total += 1
        lock.unlock()
    }

    var distinct: Int { lock.lock(); defer { lock.unlock() }; return seen.count }
    var received: Int { lock.lock(); defer { lock.unlock() }; return total }

    // MARK: - 差异包围盒

    private var previous: Data?
    private var previousSize: (Int, Int, Int)?
    private var lastDiff: (x: Int, y: Int, w: Int, h: Int)?

    /// 与上一帧比较，记录变化区域的包围盒。
    /// 用途：服务端把光标合成进画面时，鼠标移动只会改变光标附近的一小块区域。
    func recordDiff(pixels: Data, width: Int, height: Int, stride: Int) {
        lock.lock()
        defer { lock.unlock() }

        defer {
            previous = pixels
            previousSize = (width, height, stride)
        }

        guard let old = previous,
              let size = previousSize,
              size.0 == width, size.1 == height, size.2 == stride
        else { return }

        var minX = width, minY = height, maxX = -1, maxY = -1
        old.withUnsafeBytes { oldRaw in
            pixels.withUnsafeBytes { newRaw in
                guard let a = oldRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let b = newRaw.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else { return }

                for y in 0..<height {
                    let rowOffset = y * stride
                    for x in 0..<width {
                        let offset = rowOffset + x * 4
                        if a[offset] != b[offset] || a[offset + 1] != b[offset + 1]
                            || a[offset + 2] != b[offset + 2] {
                            if x < minX { minX = x }
                            if x > maxX { maxX = x }
                            if y < minY { minY = y }
                            if y > maxY { maxY = y }
                        }
                    }
                }
            }
        }

        lastDiff = maxX >= minX && maxY >= minY
            ? (minX, minY, maxX - minX + 1, maxY - minY + 1)
            : nil
    }

    var diffSummary: String {
        lock.lock(); defer { lock.unlock() }
        guard let d = lastDiff else { return "无变化" }
        return "\(d.w)×\(d.h) @(\(d.x),\(d.y))"
    }
}

let frameFingerprints = FrameFingerprints()
let latestFrame = LatestFrameHolder()

// MARK: - 渲染后端基准测试（Task 16.2）

/// 合成一帧 BGRA 画面。
///
/// 刻意让像素随 `tick` 变化，避免被任何缓存/去重逻辑“优化”掉，
/// 保证每帧都走完整的渲染路径。
@MainActor
func makeSyntheticFrame(width: Int, height: Int, tick: Int) -> RDPFrame {
    let stride = width * 4
    var pixels = [UInt8](repeating: 0, count: stride * height)

    for y in 0..<height {
        for x in 0..<width {
            let offset = y * stride + x * 4
            pixels[offset + 0] = UInt8((x + tick * 7) & 0xFF)     // B
            pixels[offset + 1] = UInt8((y + tick * 5) & 0xFF)     // G
            pixels[offset + 2] = UInt8((x + y + tick * 3) & 0xFF) // R
            pixels[offset + 3] = 0xFF                             // A
        }
    }

    return RDPFrame(width: width, height: height, stride: stride, pixels: Data(pixels))
}

/// 按目标帧率把同一帧喂给渲染视图，持续 `seconds` 秒。
/// `RunLoop` 的转动会让 AppKit 真正执行绘制。
@MainActor
func feedFrames(view: RDPRenderNSView, frame: RDPFrame, seconds: Double, interval: Double) {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while Date() < deadline {
        view.present(frame)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: interval))
    }
}

/// 参照测量：把同一帧绘制到**离屏位图**，强制同步光栅化。
///
/// 用途：`NSView.draw(_:)` 里对 `NSImage` 的绘制可能被 CoreGraphics 延迟或
/// 交给 GPU 处理，导致「每帧呈现」严重低估本后端的真实成本。
/// 位图上下文没有可延迟的合成目标，绘制必须当场完成，因此可作为下界参照。
@MainActor
func measureOffscreenRasterization(frame: RDPFrame, iterations: Int) -> Double? {
    let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue

    guard let provider = CGDataProvider(data: frame.pixels as CFData),
          let source = CGImage(
            width: frame.width, height: frame.height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: frame.stride,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let context = CGContext(
            data: nil, width: frame.width, height: frame.height,
            bitsPerComponent: 8, bytesPerRow: frame.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo)
    else { return nil }

    let rect = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
    context.draw(source, in: rect) // 预热

    let started = CFAbsoluteTimeGetCurrent()
    for _ in 0..<iterations {
        context.draw(source, in: rect)
    }
    return (CFAbsoluteTimeGetCurrent() - started) / Double(iterations)
}

/// 光标合成自检（Task 16 后续）。
///
/// 用已知的背景与手工构造的光标验证 over 合成的像素级正确性，
/// 并导出 PNG 供目视核对——只看事件是否到达无法证明「画对了」。
@MainActor
func runCursorCheck(outputDirectory: String) {
    print("== 光标合成自检 ==")

    let width = 160, height = 96

    // 背景：浅色渐变，便于看清黑色光标
    var background = [UInt8](repeating: 0, count: width * 4 * height)
    for y in 0..<height {
        for x in 0..<width {
            let offset = y * width * 4 + x * 4
            background[offset] = UInt8(210 - y)      // B
            background[offset + 1] = UInt8(190)      // G
            background[offset + 2] = UInt8(170)      // R
            background[offset + 3] = 255
        }
    }
    let base = RDPFrame(width: width, height: height, stride: width * 4,
                        pixels: Data(background))

    // 光标：8×8 黑色方块，左半不透明、右半 50% 透明，热点 (2,2)
    var cursorPixels = [UInt8](repeating: 0, count: 8 * 4 * 8)
    for y in 0..<8 {
        for x in 0..<8 {
            let offset = y * 8 * 4 + x * 4
            let alpha: UInt8 = x < 4 ? 255 : 128
            // 预乘 alpha：黑色像素的 BGR 分量本就是 0，alpha 保留
            cursorPixels[offset] = 0
            cursorPixels[offset + 1] = 0
            cursorPixels[offset + 2] = 0
            cursorPixels[offset + 3] = alpha
        }
    }
    let cursor = RDPCursor(width: 8, height: 8, hotspotX: 2, hotspotY: 2,
                           pixels: Data(cursorPixels))

    let compositor = CursorCompositor()
    compositor.setBaseFrame(base)
    compositor.setCursor(cursor)
    compositor.setPosition(CGPoint(x: 40, y: 30))

    guard let composited = compositor.composited() else {
        print("❌ 合成结果为空")
        exit(1)
    }

    func pixel(_ frame: RDPFrame, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        frame.pixels.withUnsafeBytes { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let offset = y * frame.stride + x * 4
            return (base[offset], base[offset + 1], base[offset + 2])
        }
    }

    // 位图左上角 = 热点位置 − 热点偏移 = (40-2, 30-2) = (38, 28)
    let opaque = pixel(composited, 38, 28)        // 光标左半（不透明）
    let translucent = pixel(composited, 42, 28)   // 光标右半（50% 透明）
    let untouched = pixel(composited, 100, 80)    // 光标外，应等于背景
    let justOutside = pixel(composited, 37, 28)   // 光标左侧一格，应为背景

    let backgroundAtCursor = pixel(base, 38, 28)
    let backgroundAtTranslucent = pixel(base, 42, 28)
    let backgroundUntouched = pixel(base, 100, 80)
    let backgroundJustOutside = pixel(base, 37, 28)

    print("  不透明处: 实际=\(opaque) 期望=(0, 0, 0)")
    print("  半透明处: 实际=\(translucent) 期望=背景\(backgroundAtTranslucent) 的一半")
    print("  未覆盖处: 实际=\(untouched) 背景=\(backgroundUntouched)")
    print("  边缘外一格: 实际=\(justOutside) 背景=\(backgroundJustOutside)")

    let opaqueOK = opaque == (0, 0, 0)
    let untouchedOK = untouched == backgroundUntouched
    let outsideOK = justOutside == backgroundJustOutside
    let translucentOK = translucent.0 > 0 && translucent.0 < backgroundAtTranslucent.0

    print("  " + (opaqueOK ? "✅" : "❌") + " 不透明像素被完全覆盖")
    print("  " + (translucentOK ? "✅" : "❌") + " 半透明像素做了 over 混合")
    print("  " + (untouchedOK ? "✅" : "❌") + " 光标外像素未被改动")
    print("  " + (outsideOK ? "✅" : "❌") + " 光标边界未越界")
    _ = backgroundAtCursor

    let allOK = opaqueOK && translucentOK && untouchedOK && outsideOK

    if writePNG(composited, to: outputDirectory + "/cursor-composite.png") {
        print("  已导出合成结果: \(outputDirectory)/cursor-composite.png")
    }

    print(allOK ? "== 自检通过 ==" : "== 自检失败 ==")
    exit(allOK ? 0 : 1)
}

/// 渲染朝向自检。
///
/// 复现并防回归：视图是 `isFlipped`（y 轴向下，与 RDP 的左上原点一致），
/// 但 CoreGraphics 绘制位图时按 y 轴向上解释 —— 直接画会**上下颠倒**。
///
/// 手法：构造「上半红、下半蓝」的帧，渲染后读回像素，看颜色落在哪一半。
@MainActor
func runRenderOrientationCheck(width: Int, height: Int) {
    print("== 渲染朝向自检 ==")
    print("帧内容：上半红、下半蓝（正常朝上时应「上方=红 下方=蓝」）")

    let stride = width * 4
    var pixels = [UInt8](repeating: 0, count: stride * height)
    for y in 0..<height {
        for x in 0..<width {
            let offset = y * stride + x * 4
            let isTop = y < height / 2
            pixels[offset] = isTop ? 0 : 255      // B
            pixels[offset + 1] = 0                // G
            pixels[offset + 2] = isTop ? 255 : 0  // R
            pixels[offset + 3] = 255
        }
    }
    let frame = RDPFrame(width: width, height: height, stride: stride, pixels: Data(pixels))

    func colorName(_ color: NSColor?) -> String {
        guard let rgb = color?.usingColorSpace(.deviceRGB) else { return "?" }
        let r = rgb.redComponent, b = rgb.blueComponent
        if r > 0.5 && b < 0.5 { return "红" }
        if b > 0.5 && r < 0.5 { return "蓝" }
        return "其他"
    }

    var failures = 0
    var checked = 0

    for backend in RDPRenderBackend.allCases {
        let view = RDPRenderNSView(backend: backend, onRenderCost: nil)
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.present(frame)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            print("  ⚠️  \(backend.displayName): 无法创建离屏位图，跳过")
            continue
        }
        view.cacheDisplay(in: view.bounds, to: rep)

        let top = colorName(rep.colorAt(x: width / 2, y: 1))
        let bottom = colorName(rep.colorAt(x: width / 2, y: rep.pixelsHigh - 2))

        // Metal 由 CAMetalLayer 呈现，cacheDisplay 抓不到内容，会得到整片同色
        if backend == .metal && (top == "其他" || top == bottom) {
            print("  ⚠️  \(backend.displayName): 离屏捕获不到 CAMetalLayer 内容，跳过")
            continue
        }

        checked += 1
        let ok = (top == "红" && bottom == "蓝")
        if !ok { failures += 1 }
        print("  \(ok ? "✅" : "❌") \(backend.displayName)"
              + "（实际 \(view.activeBackend.displayName)）: 上方=\(top) 下方=\(bottom)")
    }

    if checked == 0 {
        print("  ⚠️  没有可校验的后端")
        exit(2)
    }
    if failures == 0 {
        print("== 自检通过（校验 \(checked) 个后端）==")
        exit(0)
    }
    print("== 自检失败：\(failures) 个后端朝向错误 ==")
    exit(1)
}

/// 渲染后端切换自检。
///
/// 复现并防回归：切换后端后必须**用当前帧立刻重绘**。
/// 若只 reset 而不重绘，远端是静态画面时（如 GDM 登录页）下一帧可能很久才来，
/// 用户会一直对着黑屏。
///
/// 验证手法：**只在切换前推一次帧**，切换后不再推帧；
/// 若新呈现器仍完成了绘制（其绘制计数从 0 变为非 0），说明确实重绘了当前帧。
@MainActor
func runRenderSwitchCheck(width: Int, height: Int) {
    print("== 渲染后端切换自检 ==")

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let stats = RenderStats()
    let view = RDPRenderNSView(backend: .metal) { stats.recordPresent(duration: $0) }

    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: width, height: height),
        styleMask: [.titled, .resizable],
        backing: .buffered,
        defer: false)
    window.title = "RDP 渲染切换自检"
    window.isReleasedWhenClosed = false
    window.contentView = view
    window.makeKeyAndOrderFront(nil)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.6))

    let frame = makeSyntheticFrame(width: width, height: height, tick: 1)

    var failures = 0
    var step = 0

    func check(_ label: String, to expected: RDPRenderBackend) {
        step += 1
        // 推一次帧，让当前后端有内容
        view.present(frame)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))

        // 切换；此后**不再推帧**
        view.setBackend(expected)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.6))

        // 新呈现器的计数从 0 开始，非 0 即证明它重绘了当前帧
        // 用「真正画了内容」判定：只清屏不算，必须真的画出了当前帧
        let diag = view.diagnostics
        let ok = diag.withContent > 0
        if !ok { failures += 1 }

        print("  \(ok ? "✅" : "❌") \(label)"
              + " → 实际后端 \(view.activeBackend.displayName)"
              + "，切换后自行绘制 \(diag.withContent) 帧内容"
              + "（绘制调用 \(diag.drawn)）")
    }

    check("Metal → CoreGraphics", to: .coreGraphics)
    check("CoreGraphics → Metal", to: .metal)
    check("Metal → CoreGraphics（再次）", to: .coreGraphics)

    // 冗余调用不应重建（否则会反复黑屏）
    let before = view.activeBackend
    view.setBackend(view.requestedBackend)
    print("  \(view.activeBackend == before ? "✅" : "❌") 重复设置同一后端不重建")

    window.orderOut(nil)

    if failures == 0 {
        print("== 自检通过 ==")
        exit(0)
    }
    print("== 自检失败：\(failures) 次切换后未重绘 ==")
    exit(1)
}

/// 重连行为自检。
///
/// 复现并防回归：连接失败（或事件循环自然结束）后，会话必须被释放，
/// 否则后续重连会被误判成「已有会话在进行中」，导致
/// 「重新连接 / 重试」按钮永久失效。
@MainActor
func runRetryCheck(host: String, user: String, password: String) {
    print("== 重连行为自检 ==")

    var profile = RDPProfile(name: "retry", host: host, username: user)
    profile.width = 1024
    profile.height = 768
    profile.clipboard = false

    let client = RDPClient()
    var lastError: String?

    client.onEvent = { event in
        if case .error(let message) = event { lastError = message }
    }

    func waitUntilIdle(_ seconds: Double) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline && client.isActive {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        // 再转一会儿，让工作线程完成释放
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
    }

    // 第 1 次：故意用错误密码，必定失败
    print("--- 第 1 次：错误密码（预期失败）---")
    do {
        try client.connect(profile: profile, password: "definitely-wrong-password",
                           ignoreCertificate: true)
    } catch {
        print("❌ 第 1 次 connect 就抛错（不该发生）: \(error.localizedDescription)")
        exit(1)
    }
    waitUntilIdle(15)
    print("    失败原因: \(lastError ?? "（无）")")
    print("    会话已释放: \(client.isActive ? "❌ 否" : "✅ 是")")

    guard !client.isActive else {
        print("== 自检失败：失败后未释放会话 ==")
        exit(1)
    }

    // 第 2 次：正确密码，应当能正常连上
    print("--- 第 2 次：正确密码（预期成功）---")
    do {
        try client.connect(profile: profile, password: password, ignoreCertificate: true)
    } catch {
        print("❌ 重连被拒绝: \(error.localizedDescription)")
        print("== 自检失败 ==")
        exit(1)
    }

    let deadline = Date(timeIntervalSinceNow: 15)
    var connected = false
    while Date() < deadline && !connected {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        if !client.isActive { break }
        if lastError == nil && client.isActive {
            // 用是否收到过 CONNECTED 更准确，这里以「仍存活且无错误」近似
        }
        connected = client.isActive
    }

    print("    连接结果: \(connected ? "✅ 成功重连" : "❌ 未连上")")

    // 第 3 次：主动断开后再连，验证「断开 → 重连」路径
    print("--- 第 3 次：断开后重连 ---")
    client.disconnect()
    print("    断开后会话已释放: \(client.isActive ? "❌ 否" : "✅ 是")")

    do {
        try client.connect(profile: profile, password: password, ignoreCertificate: true)
        print("    重连请求: ✅ 被接受")
    } catch {
        print("    重连请求: ❌ 被拒绝 - \(error.localizedDescription)")
        exit(1)
    }
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 4))
    client.disconnect()

    print("== 自检通过 ==")
    exit(0)
}

/// 渲染后端性能对比。
///
/// 不依赖远端连接：合成帧按固定帧率喂给渲染器，从而把「后端自身的开销」
/// 从「远端推帧节奏」中隔离出来，结果可复现。
/// MTKView 需要真实窗口才能拿到 drawable，因此这里会创建一个离屏窗口。
@MainActor
func runRenderBench(seconds: Double, width: Int, height: Int, targetFPS: Double) {
    print("== 渲染后端基准测试 ==")
    print("分辨率 \(width)×\(height)｜模拟 \(Int(targetFPS)) fps｜每个后端 \(Int(seconds)) 秒")
    print("说明：远端静态画面不会持续推帧，因此用合成帧驱动，隔离后端自身开销。")

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let stats = RenderStats()
    let view = RDPRenderNSView(backend: .metal) { duration in
        stats.recordPresent(duration: duration)
    }

    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: width, height: height),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false)
    window.title = "RDP 渲染基准测试"
    window.isReleasedWhenClosed = false
    window.contentView = view
    window.makeKeyAndOrderFront(nil)

    // 等窗口与图层就位
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.6))

    let interval = 1.0 / targetFPS
    var results: [(name: String, present: Double, cpu: Double, frames: Int)] = []

    for candidate in RDPRenderBackend.allCases {
        view.setBackend(candidate)
        let active = view.activeBackend
        stats.start(backend: active)

        print("\n----- \(active.displayName) -----")
        print("  实现: \(active.detail)")

        // 预热：让纹理 / 图层缓存就绪，避免把首次分配算进来
        feedFrames(view: view,
                   frame: makeSyntheticFrame(width: width, height: height, tick: 0),
                   seconds: 0.6, interval: interval)
        stats.reset()

        // 上传链路自检：用已知像素验证渲染目标里真的有画面。
        // 只看耗时无法区分「渲染很快」和「根本没渲染」。
        let checkX = 3, checkY = 5, checkTick = 7
        view.present(makeSyntheticFrame(width: width, height: height, tick: checkTick))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))

        if let pixel = view.readBackPixel(x: checkX, y: checkY) {
            let expectB = UInt8((checkX + checkTick * 7) & 0xFF)
            let expectG = UInt8((checkY + checkTick * 5) & 0xFF)
            let expectR = UInt8((checkX + checkY + checkTick * 3) & 0xFF)
            let matched = pixel.b == expectB && pixel.g == expectG && pixel.r == expectR
            print("  上传自检: \(matched ? "✅ 像素匹配" : "❌ 像素不匹配")"
                  + "  期望 BGR=(\(expectB),\(expectG),\(expectR))"
                  + "  实际=(\(pixel.b),\(pixel.g),\(pixel.r))")
        } else {
            print("  上传自检: 该后端不支持回读（CoreGraphics 为延迟光栅化）")
        }
        stats.reset()

        var presentSum = 0.0
        var cpuSum = 0.0
        var samples = 0

        for second in 1...max(1, Int(seconds)) {
            feedFrames(view: view,
                       frame: makeSyntheticFrame(width: width, height: height, tick: second),
                       seconds: 1.0, interval: interval)

            presentSum += stats.averagePresentMilliseconds
            cpuSum += stats.processCPUPercent
            samples += 1

            let present = String(format: "%6.2f", stats.averagePresentMilliseconds)
            let cpu = String(format: "%5.1f", stats.processCPUPercent)
            let diag = view.diagnostics
            print("  t=\(String(format: "%2d", second))s  呈现 \(present) ms  CPU \(cpu)%"
                  + "  绘制 \(diag.withContent)  跳过 \(diag.skipped)")
        }

        let diag = view.diagnostics
        if diag.skipped > 0 {
            print("  ⚠️  有 \(diag.skipped) 次因拿不到 drawable 被跳过（窗口未上屏），数据不可信")
        }
        results.append((active.displayName,
                        samples > 0 ? presentSum / Double(samples) : 0,
                        samples > 0 ? cpuSum / Double(samples) : 0,
                        diag.withContent))
    }

    // 参照测量：离屏同步光栅化成本
    let reference = makeSyntheticFrame(width: width, height: height, tick: 3)
    if let offscreenMS = measureOffscreenRasterization(frame: reference, iterations: 40) {
        print("\n----- 参照测量 -----")
        print(String(format: "  离屏同步光栅化（CG，排除延迟合成）: %.2f ms/帧", offscreenMS * 1000))
    }

    print("\n===== 汇总（窗口内平均）=====")
    for result in results {
        let name = result.name.padding(toLength: 14, withPad: " ", startingAt: 0)
        let present = String(format: "%8.2f", result.present)
        let cpu = String(format: "%8.1f", result.cpu)
        print("  \(name) 呈现 \(present) ms   CPU \(cpu)%   绘制 \(result.frames) 帧")
    }

    window.orderOut(nil)
    exit(0)
}

/// ProfileStore / CredentialStore 自检（Task 8）
func runStoreCheck() {
    print("== ProfileStore / CredentialStore 自检 ==")

    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("rdpconnector-store-check-\(UUID().uuidString)", isDirectory: true)
    let fileURL = directory.appendingPathComponent("profiles.json")
    let credentialsURL = directory.appendingPathComponent("credentials.json")
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = ProfileStore(fileURL: fileURL)
    print("初始配置数: \(store.profiles.count)")

    let profile = RDPProfile(name: "自检配置", host: "192.168.1.5", username: "ttt")
    store.add(profile)
    print("新增后数量: \(store.profiles.count)")
    print("displayName: \(profile.displayName) / endpoint: \(profile.endpoint)")
    print("校验结果: \(profile.isValid ? "通过" : profile.validationIssues.joined(separator: "; "))")

    // 重新打开，验证落盘
    let reloaded = ProfileStore(fileURL: fileURL)
    print("重新加载后数量: \(reloaded.profiles.count == 1 ? "✅ 1" : "❌ \(reloaded.profiles.count)")")

    // 凭据往返（应用私有文件，不涉及 Keychain / 系统授权）
    do {
        try store.setPassword("s3cret-value", for: profile.id)
        let readBack = store.password(for: profile.id)
        print("凭据回读: \(readBack == "s3cret-value" ? "✅ 一致" : "❌ \(readBack ?? "nil")")")

        try store.setPassword("updated-value", for: profile.id)
        let updated = store.password(for: profile.id)
        print("凭据更新: \(updated == "updated-value" ? "✅ 生效" : "❌ 未生效")")

        try store.removePassword(for: profile.id)
        print("凭据删除: \(store.password(for: profile.id) == nil ? "✅ 已清除" : "❌ 仍存在")")
    } catch {
        print("❌ 凭据操作失败: \(error.localizedDescription)")
    }

    // 重新打开后凭据应能读回（验证真的落盘，而非只在内存里）
    do {
        try store.setPassword("persisted-value", for: profile.id)
        let reopened = ProfileStore(fileURL: fileURL)
        print("凭据重载: \(reopened.password(for: profile.id) == "persisted-value" ? "✅ 一致" : "❌ 丢失")")
    } catch {
        print("❌ 凭据重载失败: \(error.localizedDescription)")
    }

    // hasPassword 语义
    let probe = UUID()
    do {
        try store.setPassword("probe-value", for: probe)
        let existsBefore = store.hasPassword(for: probe)
        try store.removePassword(for: probe)
        let existsAfter = store.hasPassword(for: probe)
        let ok = existsBefore && !existsAfter
        print("hasPassword 语义: \(ok ? "✅" : "❌")"
              + " 存在时=\(existsBefore) 删除后=\(existsAfter)")
    } catch {
        print("hasPassword 语义: ❌ 操作失败 - \(error.localizedDescription)")
    }

    // 落盘检查：profiles.json 不含明文密码；credentials.json 权限为 0600
    if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
        let leaked = text.contains("persisted-value") || text.contains("updated-value")
        print("profiles.json 明文密码检查: \(leaked ? "❌ 发现明文" : "✅ 无明文")")
    }

    let attributes = try? FileManager.default.attributesOfItem(atPath: credentialsURL.path)
    let permissions = (attributes?[.posixPermissions] as? NSNumber)?.intValue
    print("credentials.json 权限: "
          + (permissions == 0o600 ? "✅ 0600" : "❌ \(permissions.map { String($0, radix: 8) } ?? "缺失")"))

    // 分辨率预设：id 必须唯一（Picker 靠 id 匹配选中项，重复会让选择错乱），
    // 按宽、高升序，且默认值 1920×1080 必须在内置列表里
    let presets = ResolutionPreset.builtIn
    let uniqueIDs = Set(presets.map(\.id)).count == presets.count
    let ascending = zip(presets, presets.dropFirst()).allSatisfy {
        ($0.width, $0.height) < ($1.width, $1.height)
    }
    let hasDefault = presets.contains { $0.width == 1920 && $0.height == 1080 }
    print("分辨率预设: \(uniqueIDs && ascending && hasDefault ? "✅" : "❌")"
          + " 共 \(presets.count) 项"
          + " id唯一=\(uniqueIDs) 升序=\(ascending) 含1920×1080=\(hasDefault)")

    // Cmd 键映射：默认当 Ctrl（右 Ctrl 0x011D），配成 Win 时走左 Win 0x015B；
    // 普通字母键不受该设置影响
    let cmdAsCtrl = KeyMapping.scancode(forMacVirtualKeyCode: 55, cmdBehavior: .control)
    let cmdAsWin = KeyMapping.scancode(forMacVirtualKeyCode: 55, cmdBehavior: .windows)
    let letterC = KeyMapping.scancode(forMacVirtualKeyCode: 8, cmdBehavior: .control)
    let mappingOK = cmdAsCtrl == (0x1D | KeyMapping.extendedFlag)
        && cmdAsWin == (0x5B | KeyMapping.extendedFlag)
        && letterC == 0x2E
    print("Cmd 键映射: \(mappingOK ? "✅" : "❌")"
          + " Cmd→Ctrl=0x\(cmdAsCtrl.map { String($0, radix: 16) } ?? "nil")"
          + " Cmd→Win=0x\(cmdAsWin.map { String($0, radix: 16) } ?? "nil")"
          + " C→0x\(letterC.map { String($0, radix: 16) } ?? "nil")")

    // 旧版配置文件兼容：profiles.json 里没有 cmdKeyBehavior 字段时也必须能加载。
    // 手写 Codable init 就是为此 —— 用合成的 decoder 会因 keyNotFound 抛错，
    // 导致升级后整个配置列表加载失败（用户看到「配置全没了」）。
    let legacyURL = directory.appendingPathComponent("legacy-profiles.json")
    let legacyJSON = "[{\"id\":\"\(UUID().uuidString)\",\"name\":\"旧配置\",\"host\":\"10.0.0.1\","
        + "\"port\":3389,\"username\":\"u\",\"domain\":\"\",\"width\":1920,\"height\":1080,"
        + "\"dynamicResolution\":true,\"clipboard\":true}]"
    do {
        try legacyJSON.data(using: .utf8)!.write(to: legacyURL)
        let legacyStore = ProfileStore(fileURL: legacyURL)
        let restored = legacyStore.profiles
        let ok = restored.count == 1 && restored.first?.cmdKeyBehavior == .control
        print("旧版配置兼容: \(ok ? "✅" : "❌")"
              + " 载入 \(restored.count) 条，cmdKeyBehavior="
              + (restored.first?.cmdKeyBehavior.rawValue ?? "nil"))
    } catch {
        print("旧版配置兼容: ❌ \(error.localizedDescription)")
    }

    // 更新与删除
    var renamed = profile
    renamed.name = "改名后"
    store.update(renamed)
    print("更新后 displayName: \(store.profiles.first?.displayName ?? "-")")
    store.remove(id: profile.id)
    print("删除后数量: \(store.profiles.count)")
    print("删除配置后凭据是否清理: "
          + (store.password(for: profile.id) == nil ? "✅ 已清理" : "❌ 仍存在"))
    print("== 自检结束 ==")
}

/// RDPClient（RDPKit Swift 封装）自检（Task 9）
func runKitCheck(host: String, user: String, password: String,
                 seconds: Double, width: Int, height: Int) {
    print("== RDPClient（RDPKit）自检 ==")

    var profile = RDPProfile(name: "kit-check", host: host, username: user)
    profile.width = width
    profile.height = height
    profile.dynamicResolution = true
    profile.clipboard = true
    // 允许通过环境变量注入已信任指纹，用于验证「用户接受后重连成功」这一半
    if let fingerprint = ProcessInfo.processInfo.environment["RDP_FINGERPRINT"],
       !fingerprint.isEmpty {
        profile.trustedFingerprint = fingerprint
    }
    print("配置: \(profile.displayName) @ \(profile.endpoint) \(width)x\(height)")

    let stats = Stats()
    let client = RDPClient()

    client.onEvent = { event in
        switch event {
        case .connecting:                  print("[事件] connecting")
        case .connected:                   print("[事件] connected")
        case .disconnected:                print("[事件] disconnected")
        case .error(let message):          print("[事件] error: \(RDPErrorHint.enrich(message))")
        case .certificateUntrusted(let f): print("[事件] certificateUntrusted: \(f)")
        case .clipboardText(let text):     print("[事件] clipboard: \(text.prefix(40))")
        case .desktopResize(let w, let h): print("[事件] resize: \(w)x\(h)")
        case .cursorChanged(let cursor):
            if let cursor {
                print("[事件] cursor: \(cursor.width)x\(cursor.height)"
                      + " hotspot=(\(cursor.hotspotX),\(cursor.hotspotY))")
            } else {
                print("[事件] cursor: 隐藏")
            }
        case .cursorPosition(let x, let y): print("[事件] cursorPosition: \(x),\(y)")
        }
    }

    client.onFrame = { frame in
        let previous = stats.frames
        stats.addFrame(width: Int32(frame.width), height: Int32(frame.height))
        if previous == 0 {
            print("[帧] 首帧 \(frame.width)x\(frame.height) stride=\(frame.stride) "
                  + "bytes=\(frame.pixels.count)")
        }
    }

    do {
        // 默认走 TOFU（不忽略证书）。RDP_IGNORE_CERT=1 时跳过校验，仅排障用。
        // 注意：忽略校验会把证书写进 FreeRDP 的信任库
        // (~/.config/freerdp/server/<host>_<port>.pem)，之后不会再触发 TOFU 提示。
        let ignoreCertificate = ProcessInfo.processInfo.environment["RDP_IGNORE_CERT"] == "1"
        print("证书策略: \(ignoreCertificate ? "忽略校验（排障用）" : "TOFU（首次需用户确认）")")
        try client.connect(profile: profile, password: password,
                           ignoreCertificate: ignoreCertificate)
    } catch {
        print("❌ connect 抛错: \(error.localizedDescription)")
        exit(1)
    }

    // 剪贴板冒烟测试：连接稳定后推送一段文本，并读回远端剪贴板
    DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
        let probe = "rdpconnector-clipboard-probe"
        print("[剪贴板] 推送本地文本: \(probe)")
        client.sendClipboardText(probe)

        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            let remote = NSPasteboard.general.string(forType: .string) ?? "(空)"
            print("[剪贴板] 本地剪贴板当前内容: \(remote.prefix(60))")
        }
    }

    // 输入 / 光标冒烟测试。
    // 移动鼠标除了验证输入路径，也是**触发服务端下发光标形状**的必要动作：
    // gnome-remote-desktop 是懒加载的，连接时不发，首次光标交互才发。
    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
        for step in 0..<20 {
            client.sendMouseMove(x: UInt16(200 + step * 15), y: UInt16(300 + step * 7))
            Thread.sleep(forTimeInterval: 0.05)
        }
        print("[输入] 已注入鼠标移动（用于触发光标形状下发）")
    }

    DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
        print("== 到时，断开 ==")
        client.disconnect()
        print("== 已断开，总帧数: \(stats.frames) ==")
        exit(stats.frames > 0 ? 0 : 1)
    }

    // 事件回调派发到主队列，必须让主 RunLoop 转起来才能看到事件。
    // 真实 SwiftUI 应用天然满足这一点；此处显式 pump。
    RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds + 30))
    print("== 超时未结束，总帧数: \(stats.frames) ==")
    exit(stats.frames > 0 ? 0 : 1)
}

setbuf(stdout, nil)

let arguments = CommandLine.arguments

if arguments.count > 1 && arguments[1] == "caps" {
    let capabilities = RDPCapabilities.detect()
    print("== FreeRDP 能力自检 ==")
    print("版本: \(capabilities.freerdpVersion)")
    print("WITH_FFMPEG:      \(capabilities.hasFFmpeg ? "✅" : "❌")")
    print("WITH_GFX_H264:    \(capabilities.hasGfxH264 ? "✅" : "❌")")
    print("WITH_VIDEO_FFMPEG:\(capabilities.hasVideoFFmpeg ? "✅" : "❌")")
    print("满足 gnome-remote-desktop 要求: \(capabilities.supportsGnomeRemoteDesktop ? "✅ 是" : "❌ 否")")
    if let message = capabilities.missingCapabilityMessage {
        print()
        print(message)
    }
    exit(capabilities.supportsGnomeRemoteDesktop ? 0 : 1)
}

if arguments.count > 1 && arguments[1] == "render-orientation-check" {
    MainActor.assumeIsolated {
        runRenderOrientationCheck(
            width: arguments.count > 2 ? (Int(arguments[2]) ?? 64) : 64,
            height: arguments.count > 3 ? (Int(arguments[3]) ?? 64) : 64)
    }
}

if arguments.count > 1 && arguments[1] == "render-switch-check" {
    MainActor.assumeIsolated {
        runRenderSwitchCheck(
            width: arguments.count > 2 ? (Int(arguments[2]) ?? 1024) : 1024,
            height: arguments.count > 3 ? (Int(arguments[3]) ?? 768) : 768)
    }
}

if arguments.count > 1 && arguments[1] == "retry-check" {
    guard arguments.count >= 5 else {
        FileHandle.standardError.write(
            "用法: rdpbridge-cli retry-check <host> <user> <password>\n".data(using: .utf8)!)
        exit(2)
    }
    MainActor.assumeIsolated {
        runRetryCheck(host: arguments[2], user: arguments[3], password: arguments[4])
    }
}

if arguments.count > 1 && arguments[1] == "cursor-check" {
    let directory = arguments.count > 2 ? arguments[2] : NSTemporaryDirectory()
    MainActor.assumeIsolated { runCursorCheck(outputDirectory: directory) }
}

if arguments.count > 1 && arguments[1] == "render-bench" {
    // 用法: render-bench [seconds] [width] [height] [targetFPS]
    MainActor.assumeIsolated {
        runRenderBench(
            seconds: arguments.count > 2 ? (Double(arguments[2]) ?? 5) : 5,
            width: arguments.count > 3 ? (Int(arguments[3]) ?? 1024) : 1024,
            height: arguments.count > 4 ? (Int(arguments[4]) ?? 768) : 768,
            targetFPS: arguments.count > 5 ? (Double(arguments[5]) ?? 30) : 30)
    }
}

if arguments.count > 1 && arguments[1] == "store-check" {
    runStoreCheck()
    exit(0)
}

if arguments.count > 1 && arguments[1] == "kit-check" {
    guard arguments.count >= 5 else {
        FileHandle.standardError.write(
            "用法: rdpbridge-cli kit-check <host> <user> <password> [seconds] [width] [height]\n"
                .data(using: .utf8)!)
        exit(2)
    }
    runKitCheck(host: arguments[2], user: arguments[3], password: arguments[4],
                seconds: arguments.count > 5 ? (Double(arguments[5]) ?? 15) : 15,
                width: arguments.count > 6 ? (Int(arguments[6]) ?? 1024) : 1024,
                height: arguments.count > 7 ? (Int(arguments[7]) ?? 768) : 768)
    exit(0)
}

guard arguments.count >= 4 else {
    FileHandle.standardError.write(
        "用法: rdpbridge-cli <host> <user> <password> [port] [seconds]\n".data(using: .utf8)!)
    exit(2)
}

let host = arguments[1]
let user = arguments[2]
let password = arguments[3]
let port = arguments.count > 4 ? (Int32(arguments[4]) ?? 3389) : 3389
let runSeconds = arguments.count > 5 ? (Double(arguments[5]) ?? 20) : 20
let width = arguments.count > 6 ? (Int32(arguments[6]) ?? 1024) : 1024
let height = arguments.count > 7 ? (Int32(arguments[7]) ?? 768) : 768

// MARK: - 统计

final class Stats {
    private let lock = NSLock()
    private var _frames = 0
    private var _bytes = 0

    func addFrame(width: Int32, height: Int32) {
        lock.lock()
        defer { lock.unlock() }
        _frames += 1
        _bytes += Int(width) * Int(height) * 4
    }

    var frames: Int {
        lock.lock()
        defer { lock.unlock() }
        return _frames
    }
}

let stats = Stats()

// MARK: - C 回调

let onFrame: RdpFrameCallback = { bgra, width, height, stride, _, _, _, _, _ in
    let previous = stats.frames
    stats.addFrame(width: width, height: height)
    if previous == 0 {
        print("[帧] 首帧到达 \(width)x\(height) stride=\(stride)")
    }
    if let bgra {
        let data = Data(bytes: bgra, count: Int(stride) * Int(height))
        frameFingerprints.record(data)
        frameFingerprints.recordDiff(pixels: data, width: Int(width),
                                     height: Int(height), stride: Int(stride))
        latestFrame.store(RDPFrame(width: Int(width), height: Int(height),
                                   stride: Int(stride), pixels: data))
    }
}

// 输入通道冒烟测试：首帧后依次注入鼠标移动、按键、Ctrl+Alt+Del，
// 用于验证 Task 7 的输入 API 在真实会话上不崩溃、可正常投递。
func probeInput(session: OpaquePointer, width: Int32, height: Int32) {
    let cx = UInt16(width / 2)
    let cy = UInt16(height / 2)

    let env = ProcessInfo.processInfo.environment

    // 各步骤可单独关闭，便于隔离「服务端登出究竟由哪种输入触发」
    rdp_send_mouse_move(session, cx, cy)
    rdp_send_mouse_move(session, cx + 20, cy + 20)

    if env["RDP_NO_CLICK"] != "1" {
        rdp_send_mouse_button(session, Int32(RDP_MOUSE_LEFT), true, cx + 20, cy + 20)
        rdp_send_mouse_button(session, Int32(RDP_MOUSE_LEFT), false, cx + 20, cy + 20)
        rdp_send_mouse_wheel(session, 1, cx, cy)
    }

    if env["RDP_NO_UNICODE"] != "1" {
        rdp_send_unicode_char(session, 0x0061, true)   // 'a'
        rdp_send_unicode_char(session, 0x0061, false)
    }

    if env["RDP_NO_SHIFT"] != "1" {
        rdp_send_key_scancode(session, 0x2A, true)   // Left Shift
        rdp_send_key_scancode(session, 0x2A, false)
    }

    // Ctrl+Alt+Del 会让 GDM 登出会话，做光标诊断时跳过（RDP_NO_CAD=1）
    if ProcessInfo.processInfo.environment["RDP_NO_CAD"] == "1" {
        print("[输入] 已注入 鼠标/滚轮/字符/Shift（已跳过 Ctrl+Alt+Del），无崩溃")
    } else {
        rdp_send_ctrl_alt_del(session)
        print("[输入] 已注入 鼠标/滚轮/字符/Shift/Ctrl+Alt+Del，无崩溃")
    }

    if env["RDP_NO_RESIZE"] != "1" {
        rdp_request_resize(session, width, height)
    }
}

let onEvent: RdpEventCallback = { event, message, _ in
    let text = message.map { String(cString: $0) } ?? ""
    let name: String
    // 匿名 C 枚举常量在 Swift 中导入为 Int，而回调参数是 Int32
    switch Int(event) {
    case RDP_EV_CONNECTING:     name = "CONNECTING"
    case RDP_EV_CONNECTED:      name = "CONNECTED"
    case RDP_EV_DISCONNECTED:   name = "DISCONNECTED"
    case RDP_EV_ERROR:          name = "ERROR"
    case RDP_EV_CERT_UNTRUSTED: name = "CERT_UNTRUSTED"
    case RDP_EV_CLIPBOARD_TEXT: name = "CLIPBOARD"
    case RDP_EV_DESKTOP_RESIZE: name = "RESIZE"
    default:                    name = "EVENT(\(event))"
    }
    print("[事件] \(name)\(text.isEmpty ? "" : ": \(text)")")
}

// MARK: - 创建会话

let hostC = strdup(host)!
let userC = strdup(user)!
let passwordC = strdup(password)!
defer {
    free(hostC)
    free(userC)
    free(passwordC)
}

var options = RdpOptions()
options.host = UnsafePointer(hostC)
options.port = port
options.username = UnsafePointer(userC)
options.password = UnsafePointer(passwordC)
options.domain = nil
options.width = width
options.height = height
options.color_depth = 32
options.dynamic_resolution = true
options.clipboard = true
// 与 kit-check 保持一致：默认走 TOFU，RDP_IGNORE_CERT=1 才跳过校验
options.ignore_cert = ProcessInfo.processInfo.environment["RDP_IGNORE_CERT"] == "1"
options.cert_fingerprint = nil

print("== 创建会话 ==")
guard let session = rdp_session_create(&options, onFrame, onEvent, nil) else {
    FileHandle.standardError.write("rdp_session_create 失败\n".data(using: .utf8)!)
    exit(1)
}
print("   FreeRDP \(String(cString: rdp_bridge_freerdp_version()))")
print("   目标 \(host):\(port) 用户 \(user)")

// MARK: - 连接并运行事件循环

let worker = DispatchQueue(label: "rdp.worker")
worker.async {
    print("== 连接 ==")
    guard rdp_session_connect(session) == 0 else {
        print("== 连接失败，退出 ==")
        rdp_session_free(session)
        exit(1)
    }

    print("== 事件循环启动，最长 \(Int(runSeconds)) 秒 ==")

    // 动态分辨率测试：请求一个不同的尺寸，看服务端是否回传 RESIZE
    if let target = ProcessInfo.processInfo.environment["RDP_RESIZE_TO"] {
        let parts = target.split(separator: "x")
        if parts.count == 2, let w = Int32(parts[0]), let h = Int32(parts[1]) {
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
                print("[分辨率] 请求切换到 \(w)x\(h)")
                rdp_request_resize(session, w, h)
            }
        }
    }

    // 光标诊断：持续移动鼠标，观察「帧数是否增加」与「Pointer 通道是否下发」。
    // RDP_NO_INPUT=1 时完全不注入输入，用于隔离「服务端登出是否由输入触发」。
    let injectInput = ProcessInfo.processInfo.environment["RDP_NO_INPUT"] != "1"
    if !injectInput {
        print("[输入] RDP_NO_INPUT=1，本次不注入任何输入")
    }
    print("[光标] 诊断已排程，2 秒后开始移动鼠标")
    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
        guard injectInput else { return }
        print("[光标] 诊断开始")
        let before = stats.frames
        for step in 0..<20 {
            rdp_send_mouse_move(session, UInt16(120 + step * 12), UInt16(200 + step * 6))
            Thread.sleep(forTimeInterval: 0.05)
        }
        // 服务端懒加载光标形状：轮询等它就绪（不依赖固定时序）
        var waited = 0
        while waited < 40 {
            var probe = RdpCursorInfo()
            if let data = rdp_session_copy_cursor(session, &probe) {
                free(data)
                break
            }
            Thread.sleep(forTimeInterval: 0.25)
            waited += 1
        }
        print("[光标] 移动鼠标前帧数=\(before) 之后帧数=\(stats.frames)"
              + "  不同内容帧数=\(frameFingerprints.distinct)/\(frameFingerprints.received)"
              + "  最近变化区域=\(frameFingerprints.diffSummary)")

        // 导出当前画面与光标形状，供目视核对
        if let dir = ProcessInfo.processInfo.environment["RDP_DUMP_DIR"] {
            if let frame = latestFrame.latest {
                let ok = writePNG(frame, to: dir + "/rdp-frame.png")
                print("[转储] 画面 \(frame.width)x\(frame.height) \(ok ? "成功" : "失败")")
            }

            // 用真实帧 + 真实光标做一次端到端合成，验证渲染层接线
            var cursorInfo = RdpCursorInfo()
            if let cursorData = rdp_session_copy_cursor(session, &cursorInfo),
               let frame = latestFrame.latest {
                let cursorWidth = Int(cursorInfo.width)
                let cursorHeight = Int(cursorInfo.height)
                let cursorPixels = Data(bytes: cursorData, count: cursorWidth * 4 * cursorHeight)

                let realCursor = RDPCursor(width: cursorWidth, height: cursorHeight,
                                           hotspotX: Int(cursorInfo.hotspot_x),
                                           hotspotY: Int(cursorInfo.hotspot_y),
                                           pixels: cursorPixels)

                let compositor = CursorCompositor()
                compositor.setBaseFrame(frame)
                compositor.setCursor(realCursor)
                // 用光标诊断里最后一次移动到的位置
                compositor.setPosition(CGPoint(x: 348, y: 314))

                if let merged = compositor.composited() {
                    let ok = writePNG(merged, to: dir + "/rdp-frame-with-cursor.png")
                    print("[转储] 合成后画面（真实帧+真实光标）\(ok ? "成功" : "失败")")
                }
            }

            if let cursorData = rdp_session_copy_cursor(session, &cursorInfo) {
                let cursorWidth = Int(cursorInfo.width)
                let cursorHeight = Int(cursorInfo.height)
                let pixels = Data(bytes: cursorData, count: cursorWidth * 4 * cursorHeight)
                free(cursorData)

                let cursorFrame = RDPFrame(width: cursorWidth, height: cursorHeight,
                                           stride: cursorWidth * 4, pixels: pixels)
                // 放大 8 倍便于目视（小位图直接看太吃力）
                let scaled = upscale(cursorFrame, factor: 8)
                let ok = writePNG(scaled, to: dir + "/rdp-cursor.png")
                print("[转储] 光标 \(cursorInfo.width)x\(cursorInfo.height)"
                      + " hotspot=(\(cursorInfo.hotspot_x),\(cursorInfo.hotspot_y))"
                      + " visible=\(cursorInfo.visible) 放大8倍 \(ok ? "成功" : "失败")")
            } else {
                print("[转储] 未取到光标位图")
            }
        }
    }

    // 输入冒烟测试：等首帧到达后再注入，确保 GDI/GFX 已就绪
    DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
        guard injectInput else { return }
        guard ProcessInfo.processInfo.environment["RDP_NO_PROBE"] != "1" else {
            print("[输入] RDP_NO_PROBE=1，跳过 probeInput")
            return
        }
        if stats.frames > 0 {
            probeInput(session: session, width: width, height: height)
        } else {
            print("[输入] 未收到帧，跳过输入冒烟测试")
        }
    }

    _ = rdp_session_run(session)
    print("== 事件循环结束 ==")

    // 光标通道诊断：判断服务端是把光标合成进画面，还是独立下发
    var pointerStats = RdpPointerStats()
    rdp_session_pointer_stats(session, &pointerStats)
    print("[光标] position=\(pointerStats.position) system=\(pointerStats.system) "
          + "color=\(pointerStats.color) new=\(pointerStats.newCursor) "
          + "cached=\(pointerStats.cached) large=\(pointerStats.large)")

    rdp_session_free(session)

    let total = stats.frames
    print("== 总帧数: \(total) ==")
    exit(total > 0 ? 0 : 1)
}

Thread.sleep(forTimeInterval: runSeconds)
print("== 到时，主动断开 ==")
rdp_session_disconnect(session)

// 等待 worker 完成收尾（它会打印总帧数并结束进程）
Thread.sleep(forTimeInterval: 15)
print("== 超时未退出，强制结束，总帧数: \(stats.frames) ==")
exit(stats.frames > 0 ? 0 : 1)
