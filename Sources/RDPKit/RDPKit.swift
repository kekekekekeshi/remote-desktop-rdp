import Foundation
import RDPBridge

/// RDPKit —— 对 C 桥接层的 Swift 封装。
///
/// 目标：把 `libfreerdp` 的复杂度完全挡在 `RDPBridge` 之后，
/// 让 SwiftUI 层只面对类型安全、符合 Swift 习惯的 API。
///
/// Task 3 阶段仅提供底层能力自检。
public enum RDPKit {

    /// 底层 libfreerdp 的版本字符串，用于启动自检与问题排查。
    public static var freerdpVersion: String {
        guard let cString = rdp_bridge_freerdp_version() else { return "unknown" }
        return String(cString: cString)
    }
}
