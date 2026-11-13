# macOS RDP 连接器 —— 构建入口
#
#   make check                 依赖与能力自检
#   make build                 编译（默认 release）
#   make run                   直接运行（开发用）
#   make app                   打包成可双击的 .app
#   make spike RDP_HOST=...    运行连通性验证脚本
#   make clean                 清理产物

SHELL   := /bin/bash
CONFIG  ?= release
APP     := RDPConnector
APP_DIR := build/$(APP).app

# 尖刺脚本参数（可覆盖）
RDP_HOST ?=
RDP_USER ?= $(shell whoami)
RDP_PORT ?= 3389

# 渲染基准测试参数
BENCH_SECONDS ?= 5
BENCH_WIDTH   ?= 1920
BENCH_HEIGHT  ?= 1080
BENCH_FPS     ?= 30

.PHONY: all build run app spike check bench cursor-check hover-check clipboard-check clean

all: build

## 编译
build:
	swift build -c $(CONFIG)

## 开发期直接运行（不打包，无 Dock 图标由 AppDelegate 显式激活）
run:
	swift run -c $(CONFIG) $(APP)

## 打包为可双击运行的 .app（默认自包含：FreeRDP 及依赖打进 Frameworks）
##   make app            自包含，约 44 MB，拷到别的 Mac 也能跑
##   make app THIN=1     只装二进制（约 1 MB），依赖本机已装 FreeRDP
app:
	@if [ "$(THIN)" = "1" ]; then \
		./scripts/build-app.sh $(CONFIG) --thin; \
	else \
		./scripts/build-app.sh $(CONFIG); \
	fi

## 依赖与编解码能力自检
check:
	@echo "===== FreeRDP 版本 ====="
	@pkg-config --modversion freerdp3 2>/dev/null || { echo "缺少 freerdp3，请执行: brew install freerdp"; exit 1; }
	@echo "===== 编解码能力（需 WITH_FFMPEG=ON / WITH_GFX_H264=ON）====="
	@command -v sdl-freerdp >/dev/null && sdl-freerdp /buildconfig 2>/dev/null \
		| grep -oE 'WITH_(FFMPEG|GFX_H264|VIDEO_FFMPEG|SWSCALE)=[A-Z]+' || echo "(未找到 sdl-freerdp)"
	@echo "===== Swift 工具链 ====="
	@swift --version 2>&1 | head -1

## 渲染后端性能对比（Metal vs CoreGraphics）
##   make bench                              默认 5 秒 / 1920x1080 / 30fps
##   make bench BENCH_SECONDS=8 BENCH_WIDTH=2560 BENCH_HEIGHT=1440
bench:
	@swift build -c $(CONFIG) >/dev/null
	@$$(swift build -c $(CONFIG) --show-bin-path)/rdpbridge-cli render-bench \
		$(BENCH_SECONDS) $(BENCH_WIDTH) $(BENCH_HEIGHT) $(BENCH_FPS)

## 鼠标移动跟踪自检（远端 hover 不跟手的回归防护）
hover-check:
	@swift build -c $(CONFIG) >/dev/null
	@$$(swift build -c $(CONFIG) --show-bin-path)/rdpbridge-cli hover-check

## 剪贴板双向自检（会真的连一次；打印每条 cliprdr 收发，不需要抓包）
##   make clipboard-check RDP_HOST=<ip> RDP_USER=<user> RDP_PASSWORD=<pw>
##   默认会驱动一次远端：Win+R 打开「运行」→ 粘贴 → 复制回来，比对文本（ROUNDTRIP=0 关闭）
##   注意 Windows 的端口非 3389 时，把端口写进 RDP_HOST（如 host:3388 需自行改 kit-check 参数）
clipboard-check:
	@if [ -z "$(RDP_HOST)" ] || [ -z "$(RDP_PASSWORD)" ]; then \
		echo "用法: make clipboard-check RDP_HOST=<ip> RDP_USER=<user> RDP_PASSWORD=<pw> [CLIPBOARD_SECONDS=30] [ROUNDTRIP=0]"; exit 1; fi
	@swift build -c $(CONFIG) >/dev/null
	@WLOG_LEVEL=$${WLOG_LEVEL:-info} RDP_CLIPBOARD_PROBE=$${ROUNDTRIP:-1} \
		$$(swift build -c $(CONFIG) --show-bin-path)/rdpbridge-cli \
		kit-check "$(RDP_HOST)" "$(RDP_USER)" "$(RDP_PASSWORD)" $${CLIPBOARD_SECONDS:-30}

## 光标合成自检（像素级验证 + 导出 PNG 供目视）
cursor-check:
	@swift build -c $(CONFIG) >/dev/null
	@mkdir -p build/shots
	@$$(swift build -c $(CONFIG) --show-bin-path)/rdpbridge-cli cursor-check build/shots

## 连通性 / 黑屏根因验证（需提供 RDP_HOST）
spike:
	@if [ -z "$(RDP_HOST)" ]; then echo "用法: make spike RDP_HOST=<ip> [RDP_USER=<user>] [RDP_PORT=3389]"; exit 1; fi
	@./scripts/validate-rdp.sh "$(RDP_HOST)" "$(RDP_USER)" "$(RDP_PORT)"

clean:
	rm -rf .build build
