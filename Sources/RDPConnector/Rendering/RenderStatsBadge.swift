import SwiftUI
import RDPRender

/// 工具栏里的渲染性能指标徽标。
///
/// 单独成一个视图，是为了让它自己观察 `RenderStats`：
/// `SessionView` 观察的是 `SessionController`，而 `stats` 是另一个
/// `ObservableObject`，需要独立订阅才会随指标刷新。
struct RenderStatsBadge: View {

    @ObservedObject var stats: RenderStats

    var body: some View {
        HStack(spacing: 10) {
            metric(icon: "speedometer", text: "\(Int(stats.fps)) fps")
            metric(icon: "clock", text: String(format: "%.2f ms", stats.averagePresentMilliseconds))
            metric(icon: "cpu", text: String(format: "%.1f%%", stats.processCPUPercent))
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
        .help("""
            渲染后端：\(stats.backend.displayName)
            实现方式：\(stats.backend.detail)

            FPS：每秒实际呈现的帧数。
              注意远端只在画面变化时推帧，静态画面（如登录页）FPS 会很低甚至为 0，
              因此单看 FPS 无法区分「后端慢」和「远端没推帧」。

            呈现耗时：每帧绘制占用的 CPU 时间，是后端自身开销的直接度量。

            进程 CPU：整个进程的 CPU 占用百分比。

            累计帧数：\(stats.totalFrames)
            """)
    }

    private func metric(icon: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
        }
    }
}
