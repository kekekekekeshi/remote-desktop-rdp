import Combine
import Darwin
import Foundation

/// 渲染性能统计。
///
/// 三项指标，每秒刷新一次：
///   - **FPS**：一秒内实际呈现的帧数
///   - **呈现耗时**：`present` 调用的平均 CPU 时间（毫秒），直接反映后端开销
///   - **进程 CPU**：整个进程的 CPU 占用百分比（基于 `task_info` 累计时间差）
///
/// 为什么要三者一起看：FPS 受远端推帧节奏影响（GDM 登录页是静态画面，
/// 无变化时服务端不推帧，FPS 会很低甚至为 0），单看 FPS 无法区分
/// 「后端慢」和「远端没推帧」。呈现耗时才是后端自身开销的直接度量。
@MainActor
public final class RenderStats: ObservableObject {

    @Published public private(set) var backend: RDPRenderBackend = .coreGraphics
    @Published public private(set) var fps: Double = 0
    @Published public private(set) var averagePresentMilliseconds: Double = 0
    @Published public private(set) var processCPUPercent: Double = 0
    @Published public private(set) var totalFrames: Int = 0

    private var framesInWindow = 0
    private var presentSecondsInWindow: Double = 0
    private var cpuSampler = ProcessCPUSampler()
    private var timer: Timer?

    public init() {}

    public func start(backend: RDPRenderBackend) {
        self.backend = backend
        reset()
        guard timer == nil else { return }

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func reset() {
        fps = 0
        averagePresentMilliseconds = 0
        processCPUPercent = 0
        totalFrames = 0
        framesInWindow = 0
        presentSecondsInWindow = 0
        cpuSampler = ProcessCPUSampler()
    }

    /// 由呈现器在每帧结束时调用，duration 为秒
    public func recordPresent(duration: Double) {
        framesInWindow += 1
        presentSecondsInWindow += duration
        totalFrames += 1
    }

    private func tick() {
        fps = Double(framesInWindow)
        averagePresentMilliseconds = framesInWindow > 0
            ? presentSecondsInWindow / Double(framesInWindow) * 1000
            : 0
        processCPUPercent = cpuSampler.sample()

        framesInWindow = 0
        presentSecondsInWindow = 0
    }

    /// 一行摘要，供工具栏展示
    public var summary: String {
        let cpu = String(format: "%.1f", processCPUPercent)
        let present = String(format: "%.2f", averagePresentMilliseconds)
        return "\(backend.displayName) · \(Int(fps)) fps · 呈现 \(present) ms · CPU \(cpu)%"
    }
}

/// 进程 CPU 占用采样：累计 CPU 时间差 / 墙钟时间差。
public struct ProcessCPUSampler {

    public init() {}

    private var lastCPUSeconds: Double = 0
    private var lastSampleTime: TimeInterval = 0

    public mutating func sample() -> Double {
        let now = Date().timeIntervalSince1970
        let cpu = Self.cpuSeconds()

        defer {
            lastCPUSeconds = cpu
            lastSampleTime = now
        }

        guard lastSampleTime > 0 else { return 0 }
        let wall = now - lastSampleTime
        guard wall > 0 else { return 0 }

        return max(0, (cpu - lastCPUSeconds) / wall * 100)
    }

    /// 取本进程累计 CPU 时间（用户态 + 内核态）。
    ///
    /// 用 `getrusage` 而非 `task_info(MACH_TASK_BASIC_INFO)`：
    /// 后者在当前环境下返回值恒为 0（CPU 指标一直是 0.0%），
    /// `getrusage` 简单可靠，且同样覆盖用户态与内核态时间。
    private static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }

        func seconds(_ value: timeval) -> Double {
            Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
        }

        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}
