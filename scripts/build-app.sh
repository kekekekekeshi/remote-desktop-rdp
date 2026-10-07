#!/usr/bin/env bash
# 把 SPM 产物组装成可双击运行的 .app bundle。
#
# 之所以需要这一步：本机只有 Command Line Tools（无 Xcode.app），
# SPM 只能产出裸可执行文件；而 SwiftUI 应用要正常获得 Dock 图标、
# 焦点、以及稳定的 bundle identifier，就必须是 .app。

set -euo pipefail

# 默认做「自包含」打包：把 FreeRDP 及其传递依赖一起打进 Contents/Frameworks，
# 换台机器（没装 Homebrew / Intel Mac 前缀不同）也能直接运行。
# 传 --thin 可跳过该步骤，只装可执行文件，适合本机快速验证。
BUNDLE_DYLIBS=1
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --thin) BUNDLE_DYLIBS=0 ;;
        *)      ARGS+=("$arg") ;;
    esac
done

CONFIG="${ARGS[0]:-release}"
APP_NAME="RDPConnector"
BUNDLE_ID="com.eashion.rdpconnector"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

APP="${ROOT}/build/${APP_NAME}.app"

echo "==> 编译 (${CONFIG})"
swift build -c "${CONFIG}" --product "${APP_NAME}"

BIN_DIR="$(swift build -c "${CONFIG}" --show-bin-path)"
BIN="${BIN_DIR}/${APP_NAME}"
[[ -x "${BIN}" ]] || { echo "找不到可执行文件: ${BIN}" >&2; exit 1; }

echo "==> 组装 ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/${APP_NAME}"

# 应用图标：从项目根的 icon.png 生成 .icns。
# 必须在 codesign 之前放进 bundle，否则图标不在签名覆盖范围内。
ICON_PLIST=""
if [[ -f "${ROOT}/icon.png" ]]; then
    "${ROOT}/scripts/make-icon.sh" "${ROOT}/icon.png" "${ROOT}/build/${APP_NAME}.icns"
    cp "${ROOT}/build/${APP_NAME}.icns" "${APP}/Contents/Resources/${APP_NAME}.icns"
    ICON_PLIST="    <key>CFBundleIconFile</key><string>${APP_NAME}</string>"
else
    echo "==> 未找到 icon.png，跳过图标"
fi

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>RDP Connector</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
${ICON_PLIST}
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

if [[ "${BUNDLE_DYLIBS}" -eq 1 ]]; then
    "${ROOT}/scripts/bundle-dylibs.sh" "${APP}"
else
    echo "==> 跳过依赖打包（--thin）"
fi

echo "==> ad-hoc 签名"
# bundle 被修改后原签名失效，必须重新签名，否则启动会异常
# （缺签名会被 Gatekeeper 拦下，也会让 TCC 权限每次都重新询问）。
# 注意这里不再用 --deep：嵌套的 dylib 已由 bundle-dylibs.sh 逐个签过，
# --deep 反而会把它们的签名重新覆盖一遍、拖慢速度。
codesign --force --sign - "${APP}" 2>&1 | sed 's/^/    /' || {
    echo "    ad-hoc 签名失败，应用仍可运行但 Gatekeeper 可能拦截" >&2
}

echo
echo "==> 完成: ${APP}"
echo "    大小: $(du -sh "${APP}" | cut -f1)"
echo "    运行: open \"${APP}\""
