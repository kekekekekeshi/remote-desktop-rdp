#!/usr/bin/env bash
# RDP 连通性 / 黑屏根因验证脚本（尖刺 D1）
#
# 用法:
#   RDP_PASSWORD='xxx' ./scripts/validate-rdp.sh <host> [user] [port]
#   ./scripts/validate-rdp.sh <host> [user] [port]      # 交互式输入密码
#
# 说明:
#   - 密码只经环境变量/标准输入传递，不写入任何文件
#   - 分阶段验证：版本能力 → 认证 → 完整连接 → 日志取证
#   - 完整连接为 GUI 会话，脚本会限时后自动结束，避免挂死

set -uo pipefail

HOST="${1:?usage: validate-rdp.sh <host> [user] [port]}"
USER_NAME="${2:-$USER}"
PORT="${3:-3389}"
CONNECT_SECONDS="${CONNECT_SECONDS:-25}"

LOG_DIR="$(mktemp -d /tmp/rdp-spike.XXXXXX)"
echo "日志目录: ${LOG_DIR}"
echo

# ---------- 定位客户端二进制 ----------
CLIENT=""
for c in sdl-freerdp sdl3-freerdp wlfreerdp xfreerdp; do
    if command -v "$c" >/dev/null 2>&1; then CLIENT="$c"; break; fi
done
if [[ -z "$CLIENT" ]]; then
    echo "!! 未找到 FreeRDP 客户端，请先 brew install freerdp" >&2
    exit 127
fi
echo "== 使用客户端: ${CLIENT} =="
echo

# ---------- 密码 ----------
if [[ -z "${RDP_PASSWORD:-}" ]]; then
    read -r -s -p "请输入 ${USER_NAME}@${HOST} 的密码: " RDP_PASSWORD
    echo
fi

# ---------- 限时执行 ----------
run_bounded() {
    local secs="$1"; shift
    "$@" &
    local pid=$!
    ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null; sleep 2; kill -KILL "$pid" 2>/dev/null ) &
    local watchdog=$!
    wait "$pid" 2>/dev/null
    local rc=$?
    kill -TERM "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null
    return $rc
}

echo "################ 阶段 1/4: 版本与编解码能力 ################"
"$CLIENT" --version 2>&1 | tee "${LOG_DIR}/version.txt"
echo
echo "---- 与 gfx / h264 / sec 相关的可用选项 ----"
"$CLIENT" --help 2>&1 | grep -iE 'gfx|h264|avc|/sec|nla|cert|dynamic-resolution|auth-only|from-stdin' \
    | tee "${LOG_DIR}/help-relevant.txt"
echo

echo "################ 阶段 2/4: 认证探测 (auth-only) ################"
# auth-only 只做 TCP+TLS+NLA/CredSSP 握手后退出，是最快验证凭据与服务端 NLA 的方式
printf '%s' "$RDP_PASSWORD" | "$CLIENT" \
    /v:"${HOST}:${PORT}" /u:"${USER_NAME}" \
    /cert:ignore \
    /auth-only \
    /from-stdin \
    /log-level:INFO \
    >"${LOG_DIR}/authonly.log" 2>&1
AUTH_RC=$?
echo "退出码: ${AUTH_RC}"
tail -30 "${LOG_DIR}/authonly.log"
echo

echo "################ 阶段 3/4: 完整连接 (GFX + AVC444) ################"
echo "将打开一个窗口，最长 ${CONNECT_SECONDS} 秒后自动关闭。"
echo "请观察：是否出现 Ubuntu 的 GDM 登录页？"
echo
printf '%s' "$RDP_PASSWORD" | run_bounded "$CONNECT_SECONDS" "$CLIENT" \
    /v:"${HOST}:${PORT}" /u:"${USER_NAME}" \
    /cert:ignore \
    /gfx:AVC444 \
    /dynamic-resolution \
    /network:auto \
    +clipboard \
    /from-stdin \
    /log-level:DEBUG \
    >"${LOG_DIR}/connect-avc444.log" 2>&1
echo "退出码: $?  (124/143 通常表示被脚本限时结束，属正常)"
echo

echo "################ 阶段 4/4: 日志取证 ################"
echo "---- GFX / H264 能力宣告 ----"
grep -iE 'RDPGFX|GraphicsPipeline|CapabilitySet|AVC444|AVC420|H264' "${LOG_DIR}/connect-avc444.log" | head -30
echo
echo "---- 帧数据到达迹象 ----"
grep -icE 'SurfaceCommand|SurfaceBits|frame|decode' "${LOG_DIR}/connect-avc444.log" \
    | xargs -I{} echo "帧相关日志行数: {}"
echo
echo "---- 错误 / 失败 ----"
grep -iE 'ERROR|WARN|fail|disconnect|reset' "${LOG_DIR}/connect-avc444.log" | head -30
echo

echo "################ 结论 ################"
if [[ $AUTH_RC -eq 0 ]]; then
    echo "[通过] 认证阶段成功：TCP + TLS + NLA/CredSSP 可用"
else
    echo "[失败] 认证阶段未通过 (rc=${AUTH_RC})，请查看 ${LOG_DIR}/authonly.log"
fi
echo "请根据窗口观察结果与上方日志判断 GFX/AVC444 是否生效。"
echo "全部日志: ${LOG_DIR}"
