/*
 * Cfreerdp —— 通过 pkg-config (freerdp3) 引入 Homebrew 版 FreeRDP 3.x 的伞形头文件。
 * 仅用于向 Swift/C 暴露 FreeRDP 的公共头，不产生任何编译产物。
 */
#ifndef CFRDP_SHIM_H
#define CFRDP_SHIM_H

#include <freerdp/freerdp.h>
#include <freerdp/version.h>
#include <freerdp/settings.h>
#include <freerdp/input.h>
#include <freerdp/update.h>
#include <freerdp/error.h>
#include <freerdp/gdi/gdi.h>

#include <winpr/wlog.h>

#endif /* CFRDP_SHIM_H */
