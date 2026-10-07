#!/usr/bin/env bash
#
# 把 .app 依赖的第三方动态库打进 bundle，做成自包含产物。
#
# 背景：默认链接的是 Homebrew 里的 FreeRDP（绝对路径
# /opt/homebrew/opt/freerdp/lib/...），换台机器（尤其 Intel Mac，
# Homebrew 前缀是 /usr/local）就启动不了。
#
# 做法：
#   1. 从可执行文件出发递归收集所有非系统依赖
#   2. 复制到 Contents/Frameworks/
#   3. 把每个库的 id 与相互引用改成 @rpath/<name>
#   4. 给可执行文件加 @executable_path/../Frameworks 搜索路径
#   5. 逐个重新签名（先库后 app）
#
# 用法: ./scripts/bundle-dylibs.sh <path/to/App.app>

set -euo pipefail

APP="${1:?用法: bundle-dylibs.sh <path/to/App.app>}"
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"

BINARY="$APP/Contents/MacOS/RDPConnector"
FRAMEWORKS="$APP/Contents/Frameworks"

[[ -x "$BINARY" ]] || { echo "找不到可执行文件: $BINARY" >&2; exit 1; }

# 列出某个 Mach-O 的依赖路径（去掉首行文件名）
list_deps() {
    otool -L "$1" 2>/dev/null | tail -n +2 | awk '{print $1}'
}

# 系统库不需要打包
is_system() {
    case "$1" in
        /usr/lib/*|/System/*|/Library/Apple/*) return 0 ;;
        *) return 1 ;;
    esac
}

echo "==> 收集依赖"
mkdir -p "$FRAMEWORKS"

dependencies=()
queue=("$BINARY")

while [[ ${#queue[@]} -gt 0 ]]; do
    current="${queue[0]}"
    queue=("${queue[@]:1}")

    while IFS= read -r dep; do
        if [[ -z "$dep" ]]; then
            continue
        fi
        if is_system "$dep"; then
            continue
        fi
        if [[ "$dep" == @* ]]; then
            # 已经是 @rpath/@loader_path 形式，说明来自我们自己的 bundle
            continue
        fi
        if [[ ! -f "$dep" ]]; then
            echo "    [警告] 依赖不存在，跳过: $dep" >&2
            continue
        fi

        # 按完整路径去重
        already=0
        for existing in ${dependencies[@]+"${dependencies[@]}"}; do
            if [[ "$existing" == "$dep" ]]; then
                already=1
                break
            fi
        done
        if [[ $already -eq 1 ]]; then
            continue
        fi

        # 再按文件名去重：Homebrew 的 /opt/homebrew/opt/X/lib/Y.dylib 是指向
        # Cellar 的符号链接，同一文件会被收集到两条路径。它们内容相同，
        # 按 basename 保留一份即可；若同名却指向不同文件则报警（会互相覆盖）。
        name="$(basename "$dep")"
        for existing in ${dependencies[@]+"${dependencies[@]}"}; do
            if [[ "$(basename "$existing")" == "$name" ]]; then
                if [[ "$(stat -f %i "$existing")" != "$(stat -f %i "$dep")" ]]; then
                    echo "    [警告] 同名但不同文件，后者被忽略: $name" >&2
                    echo "           保留: $existing" >&2
                    echo "           忽略: $dep" >&2
                fi
                already=1
                break
            fi
        done
        if [[ $already -eq 1 ]]; then
            continue
        fi

        dependencies+=("$dep")
        queue+=("$dep")
    done < <(list_deps "$current")
done

echo "    共 ${#dependencies[@]} 个第三方库"

if [[ ${#dependencies[@]} -eq 0 ]]; then
    echo "==> 没有需要打包的第三方库，跳过"
    exit 0
fi

echo "==> 复制到 Contents/Frameworks"
for dep in "${dependencies[@]}"; do
    name="$(basename "$dep")"
    if [[ ! -f "$FRAMEWORKS/$name" ]]; then
        cp "$dep" "$FRAMEWORKS/$name"
        chmod u+w "$FRAMEWORKS/$name"
    fi
done

bundled_name() {
    # 该依赖是否已被我们打进 bundle；是则输出其文件名
    local dep="$1"
    local name
    name="$(basename "$dep")"
    if [[ -f "$FRAMEWORKS/$name" ]]; then
        echo "$name"
    fi
}

echo "==> 重写安装名（库自身的 id + 库之间的引用）"
for lib in "$FRAMEWORKS"/*.dylib; do
    name="$(basename "$lib")"
    install_name_tool -id "@rpath/$name" "$lib"

    while IFS= read -r dep; do
        if [[ -z "$dep" ]] || is_system "$dep" || [[ "$dep" == @* ]]; then
            continue
        fi
        target="$(bundled_name "$dep")"
        if [[ -n "$target" ]]; then
            install_name_tool -change "$dep" "@rpath/$target" "$lib"
        fi
    done < <(list_deps "$lib")
done

echo "==> 重写可执行文件的依赖并添加 rpath"
# 避免重复添加 rpath
if ! otool -l "$BINARY" | grep -A2 LC_RPATH | grep -q '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$BINARY"
fi

while IFS= read -r dep; do
    if [[ -z "$dep" ]] || is_system "$dep" || [[ "$dep" == @* ]]; then
        continue
    fi
    target="$(bundled_name "$dep")"
    if [[ -n "$target" ]]; then
        install_name_tool -change "$dep" "@rpath/$target" "$BINARY"
    fi
done < <(list_deps "$BINARY")

echo "==> 重新签名"
for lib in "$FRAMEWORKS"/*.dylib; do
    codesign --force --sign - "$lib" 2>/dev/null || true
done
codesign --force --sign - "$APP" 2>&1 | sed 's/^/    /'

echo
echo "==> 完成。可执行文件剩余的第三方引用："
remaining="$(list_deps "$BINARY" | grep -vE '^/usr/lib|^/System|^@' || true)"
if [[ -z "$remaining" ]]; then
    echo "    （无，已完全自包含）"
else
    echo "$remaining" | sed 's/^/    /'
fi

echo
echo "==> bundle 大小: $(du -sh "$APP" | cut -f1)"
