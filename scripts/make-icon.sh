#!/usr/bin/env bash
# 从单张方形源图生成 macOS 应用图标 .icns。
#
#   ./scripts/make-icon.sh [源图.png] [输出.icns]
#
# 默认读项目根的 icon.png，产出 build/RDPConnector.icns。
# 源图要求方形、边长 >= 1024（本项目用 2048x2048）；.icns 里最大的槽位是 1024，
# 用更大的源图缩放质量更好。
#
# 依赖 sips / iconutil，二者都随 Command Line Tools 分发，无需 Xcode.app。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-${ROOT}/icon.png}"
OUT="${2:-${ROOT}/build/RDPConnector.icns}"

[[ -f "${SRC}" ]] || { echo "找不到源图: ${SRC}" >&2; exit 1; }

# .icns 的 10 个槽位。iconset 里的文件名由 iconutil 约定，不能改名。
# 逻辑尺寸 16/32/128/256/512，各带一个 @2x（即 32/64/256/512/1024）。
SLOTS=(
    "icon_16x16.png:16"
    "icon_16x16@2x.png:32"
    "icon_32x32.png:32"
    "icon_32x32@2x.png:64"
    "icon_128x128.png:128"
    "icon_128x128@2x.png:256"
    "icon_256x256.png:256"
    "icon_256x256@2x.png:512"
    "icon_512x512.png:512"
    "icon_512x512@2x.png:1024"
)

ICONSET="$(mktemp -d)/RDPConnector.iconset"
mkdir -p "${ICONSET}"
trap 'rm -rf "$(dirname "${ICONSET}")"' EXIT

echo "==> 源图: ${SRC}"
for slot in "${SLOTS[@]}"; do
    name="${slot%%:*}"
    px="${slot##*:}"
    sips -z "${px}" "${px}" "${SRC}" --out "${ICONSET}/${name}" >/dev/null
done

mkdir -p "$(dirname "${OUT}")"
iconutil --convert icns --output "${OUT}" "${ICONSET}"

echo "==> 完成: ${OUT} ($(du -h "${OUT}" | cut -f1))"
