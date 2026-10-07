import Combine

/// `@State` 的替代品。
///
/// **为什么需要它**：本机只安装了 Command Line Tools，没有 Xcode.app。
/// SwiftUI 的 `@State` 已改为宏实现（`SwiftUIMacros.StateMacro`），而该宏插件
/// 只随 Xcode 分发，CLT 里不存在（`/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/`
/// 下只有 `libObservationMacros.dylib` 与 `libSwiftMacros.dylib`）。直接使用 `@State` 会编译失败：
///
///     error: external macro implementation type 'SwiftUIMacros.StateMacro'
///            could not be found for macro 'State()'
///
/// `@StateObject` / `@ObservedObject` / `@EnvironmentObject` / `@Binding` / `@Environment`
/// 等仍是普通属性包装器，不受影响。因此这里用一个 `ObservableObject` 承载视图局部状态，
/// 通过 `@StateObject` 持有，用法与 `@State` 等价：
///
///     @StateObject private var flag = LocalState(false)
///     Toggle("开关", isOn: $flag.value)
///
/// 若日后安装了 Xcode.app，可直接把这些用法换回 `@State`。
final class LocalState<Value>: ObservableObject {

    @Published var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
