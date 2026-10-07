import AppKit
import Foundation

/// macOS 的 Command 键在远端扮演什么角色。
///
/// 这是个**习惯问题**，没有唯一正确答案：
///   - Mac 用户的肌肉记忆是 Cmd+C / Cmd+V，若把 Cmd 当 Win 键，远端（GNOME）
///     收到的是 Win+C / Win+V，什么都不会发生 —— 表现为「剪贴板不能用」
///   - 但 GNOME 的系统级快捷键（Super）又确实需要 Win 键
///
/// 因此做成可配置，默认取 `.control`（与 Parallels / VMware 的默认一致）。
public enum CmdKeyBehavior: String, Codable, CaseIterable, Identifiable {
    /// 当作 Ctrl：Cmd+C / Cmd+V / Cmd+A 等按 Linux 习惯生效
    case control
    /// 当作 Win 键（GNOME 的 Super）
    case windows

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .control: return "Ctrl"
        case .windows: return "Win 键"
        }
    }

    public var detail: String {
        switch self {
        case .control:
            return "Cmd+C / Cmd+V / Cmd+A 等按 Linux 习惯生效，符合 Mac 直觉。"
                + "代价：远端的 Win 键（Super）不再可达。"
        case .windows:
            return "保留 Win 键（Super）以使用系统级快捷键。"
                + "代价：复制粘贴要在远端按 Ctrl+C / Ctrl+V，按 Cmd+C / Cmd+V 无效。"
        }
    }
}

/// macOS 虚拟键码（`NSEvent.keyCode`）→ PS/2 扫描码。
///
/// 桥接层的约定：低 8 位是 PS/2 扫描码，bit `0x0100` 置位表示扩展键
/// （Delete、方向键、右侧修饰键、Win 键等）。
///
/// 为什么用扫描码而不是直接发字符：RDP 会话里的 Ctrl/Alt/Shift 组合、
/// 功能键、方向键都必须走扫描码路径；纯文本输入才用 `sendUnicode`。
public enum KeyMapping {

    /// 扩展键标志位，与 `rdp_bridge.h` 中的约定一致
    public static let extendedFlag: UInt16 = 0x0100

    /// 普通键（无扩展前缀）
    private static let basic: [UInt16: UInt16] = [
        // 字母
        0: 0x1E,   // a
        11: 0x30,  // b
        8: 0x2E,   // c
        2: 0x20,   // d
        14: 0x12,  // e
        3: 0x21,   // f
        5: 0x22,   // g
        4: 0x23,   // h
        34: 0x17,  // i
        38: 0x24,  // j
        40: 0x25,  // k
        37: 0x26,  // l
        46: 0x32,  // m
        45: 0x31,  // n
        31: 0x18,  // o
        35: 0x19,  // p
        12: 0x10,  // q
        15: 0x13,  // r
        1: 0x1F,   // s
        17: 0x14,  // t
        32: 0x16,  // u
        9: 0x2F,   // v
        13: 0x11,  // w
        7: 0x2D,   // x
        16: 0x15,  // y
        6: 0x2C,   // z
        // 数字
        18: 0x02,  // 1
        19: 0x03,  // 2
        20: 0x04,  // 3
        21: 0x05,  // 4
        23: 0x06,  // 5
        22: 0x07,  // 6
        26: 0x08,  // 7
        28: 0x09,  // 8
        25: 0x0A,  // 9
        29: 0x0B,  // 0
        // 符号
        27: 0x0C,  // -
        24: 0x0D,  // =
        33: 0x1A,  // [
        30: 0x1B,  // ]
        41: 0x27,  // ;
        39: 0x28,  // '
        42: 0x2B,  // \
        43: 0x33,  // ,
        47: 0x34,  // .
        44: 0x35,  // /
        50: 0x29,  // `
        // 控制键
        36: 0x1C,  // Return
        48: 0x0F,  // Tab
        49: 0x39,  // Space
        51: 0x0E,  // Delete（退格）
        53: 0x01,  // Escape
        57: 0x3A,  // CapsLock
        59: 0x1D,  // 左 Control
        56: 0x2A,  // 左 Shift
        58: 0x38,  // 左 Option（远端 Alt）
        // 功能键
        122: 0x3B, // F1
        120: 0x3C, // F2
        99: 0x3D,  // F3
        118: 0x3E, // F4
        96: 0x3F,  // F5
        97: 0x40,  // F6
        98: 0x41,  // F7
        100: 0x42, // F8
        101: 0x43, // F9
        109: 0x44, // F10
        103: 0x57, // F11
        111: 0x58, // F12
    ]

    /// 扩展键（需要 0xE0 前缀）
    private static let extended: [UInt16: UInt16] = [
        62: 0x1D,  // 右 Control
        60: 0x2A,  // 右 Shift
        61: 0x38,  // 右 Option
        117: 0x53, // Forward Delete
        115: 0x47, // Home
        119: 0x4F, // End
        116: 0x49, // Page Up
        121: 0x51, // Page Down
        123: 0x4B, // ←
        124: 0x4D, // →
        125: 0x50, // ↓
        126: 0x48, // ↑
        // 注意：Command（55 / 54）不在这里 —— 它按用户的 CmdKeyBehavior 决定映射成
        // Ctrl 还是 Win 键，见 commandScancode
    ]

    /// Command 键的目标扫描码。
    ///
    /// 当作 Ctrl 时用**右侧** Ctrl 的扫描码：Mac 上的左 Ctrl（59）已占用左侧 0x1D，
    /// 让 Cmd 走右侧可以避免「同时按住 Ctrl 和 Cmd」时两者互相顶掉。
    private static func commandScancode(forMacVirtualKeyCode keyCode: UInt16,
                                        behavior: CmdKeyBehavior) -> UInt16? {
        switch (keyCode, behavior) {
        case (55, .control): return 0x1D | extendedFlag  // 左 Cmd → 右 Ctrl
        case (54, .control): return 0x1D | extendedFlag  // 右 Cmd → 右 Ctrl
        case (55, .windows): return 0x5B | extendedFlag  // 左 Cmd → 左 Win
        case (54, .windows): return 0x5C | extendedFlag  // 右 Cmd → 右 Win
        default: return nil
        }
    }

    /// 把 macOS 虚拟键码转换为桥接层可用的扫描码。未知键返回 nil。
    ///
    /// - Parameter cmdBehavior: Command 键扮演 Ctrl 还是 Win 键，见 `CmdKeyBehavior`
    public static func scancode(forMacVirtualKeyCode keyCode: UInt16,
                               cmdBehavior: CmdKeyBehavior = .control) -> UInt16? {
        if let command = commandScancode(forMacVirtualKeyCode: keyCode, behavior: cmdBehavior) {
            return command
        }
        if let code = basic[keyCode] { return code }
        if let code = extended[keyCode] { return code | extendedFlag }
        return nil
    }

    /// 该键是否为修饰键（修饰键的按下/抬起来自 `flagsChanged`，不是 `keyDown`）
    public static func isModifier(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 55, 54, 56, 60, 59, 62, 58, 61, 57: // Command / Shift / Control / Option / CapsLock
            return true
        default:
            return false
        }
    }
}
