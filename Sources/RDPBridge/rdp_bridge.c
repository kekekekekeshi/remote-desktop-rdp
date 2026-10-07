/*
 * RDPBridge 实现 —— libfreerdp 的唯一接触面。
 *
 * 本文件按任务计划分阶段实现：
 *   Task 4  会话生命周期 + settings 装配          ← 当前
 *   Task 5  连接 / 事件循环 / 错误可见
 *   Task 6  帧回调与画面输出
 *   Task 7  输入注入
 */

#include "rdp_bridge.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <freerdp/addin.h>
#include <freerdp/channels/channels.h>
#include <freerdp/channels/cliprdr.h>
#include <freerdp/channels/disp.h>
#include <freerdp/channels/rdpgfx.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/client/disp.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/client/rdpgfx.h>
#include <freerdp/codec/color.h>
#include <freerdp/display.h>
#include <freerdp/event.h>
#include <freerdp/freerdp.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/gdi/gfx.h>
#include <freerdp/input.h>
#include <freerdp/settings.h>
#include <freerdp/version.h>
#include <winpr/interlocked.h>
#include <winpr/synch.h>
#include <winpr/wlog.h>

/*
 * 连接成功后在多少秒内一帧都没收到，就判定为「已连接但无画面」。
 * 这正是「黑屏」的显式化：gnome-remote-desktop 在客户端未正确宣告
 * GFX/H.264 时会保持连接但不推送可解码的画面。
 */
#define RDP_NO_FRAME_TIMEOUT_SECONDS 10

#define RDP_CURSOR_CACHE_SIZE 32
#define RDP_CURSOR_MAX_DIM    512

typedef struct {
    uint8_t *bgra; /* 预乘 alpha，width*height*4 */
    int      width;
    int      height;
    int      hotspot_x;
    int      hotspot_y;
} RdpCursorBitmap;

/* ------------------------------------------------------------------ */
/* 内部类型                                                             */
/* ------------------------------------------------------------------ */

/*
 * 自定义上下文。
 * 必须把 rdpContext 放在结构体最前面 —— FreeRDP 依赖这一布局。
 */
typedef struct {
    rdpContext  context;
    RdpSession *session;
} RdpBridgeContext;

struct RdpSession {
    freerdp   *instance;
    RdpOptions options;          /* 原样保存（指针字段仅供读取，实际用下面的副本） */

    /* 深拷贝后的字符串 */
    char *host;
    char *username;
    char *password;
    char *domain;
    char *cert_fingerprint;

    RdpFrameCallback on_frame;
    RdpEventCallback on_event;
    void            *user;

    CRITICAL_SECTION lock;
    BOOL             lock_ready;

    volatile LONG    stop_requested;

    /* 帧活动统计，用于「连接成功但无画面」检测 */
    volatile LONG    frame_count;
    volatile LONG    no_frame_reported;
    time_t           connected_at;

    /* 动态分辨率：必须走 disp 动态通道，不能用 MONITOR_LAYOUT PDU */
    DispClientContext *disp;

    /* 光标更新统计 */
    RdpPointerStats pointer_stats;

    /* 当前光标形状（BGRA32 预乘 alpha） */
    uint8_t *cursor_bgra;
    int      cursor_width;
    int      cursor_height;
    int      cursor_hotspot_x;
    int      cursor_hotspot_y;
    int      cursor_visible;

    /* 光标形状缓存：服务端用 cacheIndex 引用先前下发的形状 */
    RdpCursorBitmap cursor_cache[RDP_CURSOR_CACHE_SIZE];

    /* 剪贴板 */
    CliprdrClientContext *cliprdr;
    char                 *clipboard_text; /* 本地待发送文本（UTF-8） */
};

/* ------------------------------------------------------------------ */
/* 工具函数                                                             */
/* ------------------------------------------------------------------ */

static char *bridge_strdup(const char *src)
{
    if (!src)
        return NULL;

    const size_t len = strlen(src) + 1;
    char *copy = (char *)malloc(len);
    if (copy)
        memcpy(copy, src, len);
    return copy;
}

static void emit_event(RdpSession *session, int event, const char *message)
{
    if (session && session->on_event)
        session->on_event(event, message, session->user);
}

/* ------------------------------------------------------------------ */
/* settings 装配                                                        */
/* ------------------------------------------------------------------ */

static BOOL apply_settings(RdpSession *session)
{
    rdpSettings      *settings = session->instance->context->settings;
    const RdpOptions *o        = &session->options;

    /* ---- 连接目标与凭据 ---- */
    if (!freerdp_settings_set_string(settings, FreeRDP_ServerHostname, session->host))
        return FALSE;

    const UINT32 port = (o->port > 0) ? (UINT32)o->port : 3389u;
    if (!freerdp_settings_set_uint32(settings, FreeRDP_ServerPort, port))
        return FALSE;

    if (session->username &&
        !freerdp_settings_set_string(settings, FreeRDP_Username, session->username))
        return FALSE;

    if (session->password &&
        !freerdp_settings_set_string(settings, FreeRDP_Password, session->password))
        return FALSE;

    if (session->domain &&
        !freerdp_settings_set_string(settings, FreeRDP_Domain, session->domain))
        return FALSE;

    /* ---- 显示参数 ---- */
    const UINT32 width  = (o->width  > 0) ? (UINT32)o->width  : 1024u;
    const UINT32 height = (o->height > 0) ? (UINT32)o->height : 768u;
    const UINT32 depth  = (o->color_depth > 0) ? (UINT32)o->color_depth : 32u;

    freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, width);
    freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, height);
    freerdp_settings_set_uint32(settings, FreeRDP_ColorDepth, depth);

    /* ---- 解决黑屏的核心：NLA + GFX 图形管线 + H.264 ---- */
    /*
     * gnome-remote-desktop (GNOME 46+) 在能力交换阶段强制要求客户端宣告
     * MS-RDPEGFX。缺少 GFX 时服务端会直接关闭连接，或只推送黑帧。
     * 这三项缺一不可（尖刺 D1 已验证，见 docs/spike-result.md）。
     */
    freerdp_settings_set_bool(settings, FreeRDP_NegotiateSecurityLayer, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_Authentication, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_GfxH264, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_GfxAVC444, TRUE);

    /* ---- 动态通道 / 分辨率 / 剪贴板 ---- */
    freerdp_settings_set_bool(settings, FreeRDP_SupportDynamicChannels, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_SupportDisplayControl,
                              o->dynamic_resolution ? TRUE : FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_RedirectClipboard,
                              o->clipboard ? TRUE : FALSE);

    /* ---- 证书 ---- */
    freerdp_settings_set_bool(settings, FreeRDP_IgnoreCertificate,
                              o->ignore_cert ? TRUE : FALSE);

    return TRUE;
}

/* ------------------------------------------------------------------ */
/* 通道插件加载                                                          */
/* ------------------------------------------------------------------ */

/*
 * 必须加载通道插件，GFX 才能协商成功。
 *
 * 原因：gnome-remote-desktop 强制要求 MS-RDPEGFX，而 GFX 由动态虚拟通道
 * drdynvc 承载。不加载通道时客户端不会宣告 GFX，服务端在能力交换阶段直接
 * 回 DEACTIVATE_ALL 并断开。实测报错：
 *   expected PDU_TYPE_DEMAND_ACTIVE[0x1], got PDU_TYPE_DEACTIVATE_ALL[0x6]
 *   ERRCONNECT_CONNECT_TRANSPORT_FAILED [0x0002000D]
 *
 * 两个必须同时满足的条件（否则通道会「加载成功」但实际不生效）：
 *
 * 1) Homebrew 的 FreeRDP 把通道静态编译进 libfreerdp-client3，磁盘上没有插件
 *    文件，FreeRDP 默认的按文件动态加载会失败，需注册静态 addin provider。
 *
 * 2) 必须通过 instance->LoadChannels 回调加载，而不是在 PreConnect 里直接加载。
 *    freerdp_connect_begin 在 PreConnect 之后会调用 utils_reload_channels()，
 *    该函数会 **销毁并重建** 通道管理器，然后回调 instance->LoadChannels 重新
 *    加载通道。若该回调为空（默认），PreConnect 里加载的通道会被整体丢弃，
 *    最终 MCS 协商的通道数为 0，服务端在能力交换阶段回 DEACTIVATE_ALL。
 *    FreeRDP 客户端公共层同样是在 client_new 中设置 LoadChannels
 *    （见其 x_client.c: instance->LoadChannels = freerdp_client_load_channels）。
 *
 *    另外 FreeRDP 用线程局部的 g_Instance 供 VirtualChannelInit 使用，
 *    它由 freerdp_channels_register_instance() 设置，utils_reload_channels
 *    在回调 LoadChannels 前也会重新注册，因此时机是安全的。
 */
static volatile LONG g_addin_provider_registered = 0;

static PVIRTUALCHANNELENTRY bridge_addin_provider(LPCSTR name, LPCSTR subsystem, LPCSTR type,
                                                  DWORD flags)
{
    return freerdp_channels_load_static_addin_entry(name, subsystem, type, flags);
}

static void ensure_addin_provider_registered(void)
{
    if (InterlockedCompareExchange(&g_addin_provider_registered, 1, 0) == 0)
        freerdp_register_addin_provider(bridge_addin_provider, 0);
}

/* 作为 instance->LoadChannels 使用：加载静态通道并注册 DVC 插件（含 rdpgfx） */
static BOOL bridge_load_channels(freerdp *instance)
{
    if (!instance || !instance->context)
        return FALSE;

    rdpContext  *context  = instance->context;
    rdpSettings *settings = context->settings;
    rdpChannels *channels = context->channels;

    /*
     * freerdp_client_add_static_channel 的 count 是 params 数组长度，
     * params[0] 才是通道名，其余元素为通道选项，因此每个通道单独调用一次。
     */
    static const char *const channelNames[] = { "rdpdr", "rdpsnd", "cliprdr", "drdynvc" };
    const size_t channelCount = sizeof(channelNames) / sizeof(channelNames[0]);

    ensure_addin_provider_registered();

    for (size_t i = 0; i < channelCount; ++i) {
        const char *params[1] = { channelNames[i] };
        if (!freerdp_client_add_static_channel(settings, 1, params))
            return FALSE;
    }

    return freerdp_client_load_addins(channels, settings);
}

/* ------------------------------------------------------------------ */
/* 剪贴板（CLIPRDR，文本双向同步）                                        */
/* ------------------------------------------------------------------ */

#define RDP_CF_UNICODETEXT     13
#define RDP_CLIPBOARD_MAX_BYTES (1024 * 1024) /* 1 MiB，超出直接丢弃 */

/* UTF-16LE → UTF-8。返回 malloc 的字符串，调用方负责 free。 */
static char *utf16le_to_utf8(const BYTE *data, size_t byteLen)
{
    if (!data || byteLen < 2)
        return NULL;

    const size_t units = byteLen / 2;
    char *out = (char *)malloc(byteLen * 3 / 2 + 4);
    if (!out)
        return NULL;

    size_t o = 0;
    for (size_t i = 0; i < units; ++i) {
        UINT32 cp = (UINT32)data[2 * i] | ((UINT32)data[2 * i + 1] << 8);
        if (cp == 0)
            break; /* 结尾 NUL */

        /* 处理代理对 */
        if (cp >= 0xD800 && cp <= 0xDBFF && (i + 1) < units) {
            const UINT32 low = (UINT32)data[2 * (i + 1)] | ((UINT32)data[2 * (i + 1) + 1] << 8);
            if (low >= 0xDC00 && low <= 0xDFFF) {
                cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
                ++i;
            }
        }

        if (cp < 0x80) {
            out[o++] = (char)cp;
        } else if (cp < 0x800) {
            out[o++] = (char)(0xC0 | (cp >> 6));
            out[o++] = (char)(0x80 | (cp & 0x3F));
        } else if (cp < 0x10000) {
            out[o++] = (char)(0xE0 | (cp >> 12));
            out[o++] = (char)(0x80 | ((cp >> 6) & 0x3F));
            out[o++] = (char)(0x80 | (cp & 0x3F));
        } else {
            out[o++] = (char)(0xF0 | (cp >> 18));
            out[o++] = (char)(0x80 | ((cp >> 12) & 0x3F));
            out[o++] = (char)(0x80 | ((cp >> 6) & 0x3F));
            out[o++] = (char)(0x80 | (cp & 0x3F));
        }
    }

    out[o] = '\0';
    return out;
}

/* UTF-8 → UTF-16LE（含结尾 NUL）。返回 malloc 的缓冲区，*outLen 为字节数。 */
static BYTE *utf8_to_utf16le(const char *text, size_t *outLen)
{
    if (!text)
        return NULL;

    const size_t n = strlen(text);
    BYTE *out = (BYTE *)malloc((n + 1) * 2 + 4);
    if (!out)
        return NULL;

    size_t i = 0, o = 0;
    while (i < n) {
        const unsigned char c = (unsigned char)text[i];
        UINT32 cp = 0;
        size_t extra = 0;

        if (c < 0x80) {
            cp = c;
        } else if ((c & 0xE0) == 0xC0) {
            cp = c & 0x1Fu;
            extra = 1;
        } else if ((c & 0xF0) == 0xE0) {
            cp = c & 0x0Fu;
            extra = 2;
        } else if ((c & 0xF8) == 0xF0) {
            cp = c & 0x07u;
            extra = 3;
        } else {
            ++i; /* 非法起始字节，跳过 */
            continue;
        }

        if (i + extra >= n)
            break;
        for (size_t k = 1; k <= extra; ++k)
            cp = (cp << 6) | ((unsigned char)text[i + k] & 0x3Fu);
        i += extra + 1;

        if (cp < 0x10000) {
            out[o++] = (BYTE)(cp & 0xFF);
            out[o++] = (BYTE)((cp >> 8) & 0xFF);
        } else {
            cp -= 0x10000;
            const UINT32 hi = 0xD800 + (cp >> 10);
            const UINT32 lo = 0xDC00 + (cp & 0x3FF);
            out[o++] = (BYTE)(hi & 0xFF);
            out[o++] = (BYTE)((hi >> 8) & 0xFF);
            out[o++] = (BYTE)(lo & 0xFF);
            out[o++] = (BYTE)((lo >> 8) & 0xFF);
        }
    }

    out[o++] = 0;
    out[o++] = 0;
    if (outLen)
        *outLen = o;
    return out;
}

/* 向服务端宣告本地有文本可粘贴 */
static UINT bridge_cliprdr_advertise_text(RdpSession *session)
{
    if (!session || !session->cliprdr)
        return CHANNEL_RC_OK;

    EnterCriticalSection(&session->lock);
    const BOOL hasText = session->clipboard_text && session->clipboard_text[0] != '\0';
    LeaveCriticalSection(&session->lock);

    if (!hasText)
        return CHANNEL_RC_OK;

    CLIPRDR_FORMAT format = { 0 };
    format.formatId = RDP_CF_UNICODETEXT;
    format.formatName = NULL;

    CLIPRDR_FORMAT_LIST list = { 0 };
    list.common.msgType = CB_FORMAT_LIST;
    list.common.msgFlags = 0;
    list.numFormats = 1;
    list.formats = &format;

    return session->cliprdr->ClientFormatList(session->cliprdr, &list);
}

static UINT bridge_cliprdr_monitor_ready(CliprdrClientContext *context,
                                         const CLIPRDR_MONITOR_READY *monitorReady)
{
    (void)monitorReady;
    RdpSession *session = context ? (RdpSession *)context->custom : NULL;
    return bridge_cliprdr_advertise_text(session);
}

/* 服务端宣告了可用格式：若含文本，主动请求内容 */
static UINT bridge_cliprdr_server_format_list(CliprdrClientContext *context,
                                              const CLIPRDR_FORMAT_LIST *formatList)
{
    if (!context || !formatList)
        return CHANNEL_RC_OK;

    for (UINT32 i = 0; i < formatList->numFormats; ++i) {
        if (formatList->formats[i].formatId == RDP_CF_UNICODETEXT) {
            CLIPRDR_FORMAT_DATA_REQUEST request = { 0 };
            request.common.msgType = CB_FORMAT_DATA_REQUEST;
            request.common.msgFlags = 0;
            request.requestedFormatId = RDP_CF_UNICODETEXT;
            return context->ClientFormatDataRequest(context, &request);
        }
    }

    return CHANNEL_RC_OK;
}

/* 收到远端文本 → 上报给上层写进本地剪贴板 */
static UINT bridge_cliprdr_server_format_data_response(
    CliprdrClientContext *context, const CLIPRDR_FORMAT_DATA_RESPONSE *response)
{
    if (!context || !response)
        return CHANNEL_RC_OK;

    RdpSession *session = (RdpSession *)context->custom;
    if (!session)
        return CHANNEL_RC_OK;

    const BYTE *data = response->requestedFormatData;
    const UINT32 length = response->common.dataLen;

    if (!data || length == 0 || length > RDP_CLIPBOARD_MAX_BYTES)
        return CHANNEL_RC_OK;

    char *utf8 = utf16le_to_utf8(data, length);
    if (utf8) {
        emit_event(session, RDP_EV_CLIPBOARD_TEXT, utf8);
        free(utf8);
    }

    return CHANNEL_RC_OK;
}

/* 服务端请求本地剪贴板内容 → 用待发送文本回应 */
static UINT bridge_cliprdr_server_format_data_request(
    CliprdrClientContext *context, const CLIPRDR_FORMAT_DATA_REQUEST *request)
{
    if (!context || !request)
        return CHANNEL_RC_OK;

    RdpSession *session = (RdpSession *)context->custom;

    CLIPRDR_FORMAT_DATA_RESPONSE response = { 0 };
    response.common.msgType = CB_FORMAT_DATA_RESPONSE;

    if (!session || request->requestedFormatId != RDP_CF_UNICODETEXT) {
        response.common.msgFlags = CB_RESPONSE_FAIL;
        return context->ClientFormatDataResponse(context, &response);
    }

    EnterCriticalSection(&session->lock);
    char *text = session->clipboard_text ? bridge_strdup(session->clipboard_text) : NULL;
    LeaveCriticalSection(&session->lock);

    size_t byteCount = 0;
    BYTE *utf16 = text ? utf8_to_utf16le(text, &byteCount) : NULL;
    free(text);

    if (!utf16) {
        response.common.msgFlags = CB_RESPONSE_FAIL;
        return context->ClientFormatDataResponse(context, &response);
    }

    response.common.msgFlags = CB_RESPONSE_OK;
    response.common.dataLen = (UINT32)byteCount;
    response.requestedFormatData = utf16;

    const UINT rc = context->ClientFormatDataResponse(context, &response);
    free(utf16);
    return rc;
}

/* ------------------------------------------------------------------ */
/* FreeRDP 回调                                                         */
/* ------------------------------------------------------------------ */

/*
 * 动态通道连接回调。
 *
 * 关键：GFX 管线必须显式接到 GDI 上，解码后的 H.264 帧才会被合成进
 * gdi->primary_buffer。不接这一步，画面永远是空的（即「黑屏」）。
 *
 * 这里自己处理而不用 freerdp_client_OnChannelConnectedEventHandler，
 * 是因为后者假定传入的是客户端公共层的 rdpClientContext，
 * 与本桥接层使用的裸 rdpContext 不兼容。
 */
static void bridge_on_channel_connected(void *context, const ChannelConnectedEventArgs *e)
{
    rdpContext *rdpcontext = (rdpContext *)context;
    if (!rdpcontext || !e || !e->name)
        return;

    RdpSession *session = ((RdpBridgeContext *)rdpcontext)->session;

    if (strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0) {
        RdpgfxClientContext *gfx = (RdpgfxClientContext *)e->pInterface;
        if (gfx && rdpcontext->gdi)
            gdi_graphics_pipeline_init(rdpcontext->gdi, gfx);
        return;
    }

    if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
        /* 动态分辨率必须通过 disp 通道下发 */
        if (session)
            session->disp = (DispClientContext *)e->pInterface;
        return;
    }

    if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        CliprdrClientContext *cliprdr = (CliprdrClientContext *)e->pInterface;
        if (!cliprdr || !session)
            return;

        session->cliprdr = cliprdr;
        /* FreeRDP 内部只把 custom 置空、从不读取，可安全用作回指 */
        cliprdr->custom = session;

        /* 覆盖默认回调，由本桥接层实现文本剪贴板 */
        cliprdr->MonitorReady             = bridge_cliprdr_monitor_ready;
        cliprdr->ServerFormatList         = bridge_cliprdr_server_format_list;
        cliprdr->ServerFormatDataRequest  = bridge_cliprdr_server_format_data_request;
        cliprdr->ServerFormatDataResponse = bridge_cliprdr_server_format_data_response;
    }
}

static void bridge_on_channel_disconnected(void *context, const ChannelDisconnectedEventArgs *e)
{
    rdpContext *rdpcontext = (rdpContext *)context;
    if (!rdpcontext || !e || !e->name)
        return;

    RdpSession *session = ((RdpBridgeContext *)rdpcontext)->session;

    if (strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0) {
        RdpgfxClientContext *gfx = (RdpgfxClientContext *)e->pInterface;
        if (gfx && rdpcontext->gdi)
            gdi_graphics_pipeline_uninit(rdpcontext->gdi, gfx);
        return;
    }

    if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0 && session) {
        session->disp = NULL;
        return;
    }

    if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0 && session) {
        /* 重定向会重建通道，旧上下文必须失效，避免悬空指针 */
        session->cliprdr = NULL;
    }
}

/*
 * 画面更新回调。FreeRDP 在每次画面合成完成后触发 EndPaint。
 *
 * 说明：MVP 上报整帧（dirty 矩形为全屏）。按脏矩形增量上报是后续优化项，
 * 回调签名已预留相关参数。
 */
static BOOL bridge_end_paint(rdpContext *context)
{
    RdpBridgeContext *ctx     = (RdpBridgeContext *)context;
    RdpSession       *session = ctx ? ctx->session : NULL;

    if (!session || !session->on_frame)
        return TRUE;

    rdpGdi *gdi = context->gdi;
    if (!gdi || !gdi->primary_buffer || gdi->width <= 0 || gdi->height <= 0 || gdi->stride == 0)
        return TRUE;

    InterlockedIncrement(&session->frame_count);

    session->on_frame(gdi->primary_buffer, gdi->width, gdi->height, (int)gdi->stride,
                      0, 0, gdi->width, gdi->height, session->user);
    return TRUE;
}

/*
 * 远端分辨率变化回调。
 *
 * GFX 的 ResetGraphics PDU 会强制要求此回调存在，否则触发致命断言：
 *   winpr_int_assert: ((update->DesktopResize)) [libfreerdp/gdi/gfx.c:gdi_ResetGraphics]
 * 职责：按 settings 中的新尺寸重建本地 GDI 帧缓冲，并通知上层。
 */
static BOOL bridge_desktop_resize(rdpContext *context)
{
    if (!context)
        return FALSE;

    rdpSettings *settings = context->settings;
    if (!settings)
        return FALSE;

    const UINT32 width  = freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth);
    const UINT32 height = freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight);

    rdpGdi *gdi = context->gdi;
    if (gdi && !gdi_resize(gdi, width, height))
        return FALSE;

    RdpBridgeContext *ctx     = (RdpBridgeContext *)context;
    RdpSession       *session = ctx ? ctx->session : NULL;
    if (session) {
        char buffer[32];
        snprintf(buffer, sizeof(buffer), "%ux%u", (unsigned)width, (unsigned)height);
        emit_event(session, RDP_EV_DESKTOP_RESIZE, buffer);
    }

    return TRUE;
}

/* ---------------- 光标（Pointer） ---------------- */

static void cursor_bitmap_free(RdpCursorBitmap *bitmap)
{
    if (!bitmap)
        return;
    free(bitmap->bgra);
    memset(bitmap, 0, sizeof(*bitmap));
}

/*
 * 把 RDP 光标掩码解码成 BGRA32（预乘 alpha）。
 *
 * 掩码的行序、位序、1/16/24/32bpp 各种格式都由 FreeRDP 的
 * freerdp_image_copy_from_pointer_data() 处理，避免自行实现出错。
 */
static uint8_t *cursor_decode(int xor_bpp, int width, int height, const BYTE *xor_mask,
                              UINT32 xor_len, const BYTE *and_mask, UINT32 and_len)
{
    if (width <= 0 || height <= 0 || width > RDP_CURSOR_MAX_DIM || height > RDP_CURSOR_MAX_DIM)
        return NULL;

    const UINT32 stride = (UINT32)width * 4;
    uint8_t *bgra = (uint8_t *)calloc(1, (size_t)stride * (size_t)height);
    if (!bgra)
        return NULL;

    if (!freerdp_image_copy_from_pointer_data(bgra, PIXEL_FORMAT_BGRA32, stride, 0, 0,
                                              (UINT32)width, (UINT32)height, xor_mask, xor_len,
                                              and_mask, and_len, (UINT32)xor_bpp, NULL)) {
        free(bgra);
        return NULL;
    }

    return bgra;
}

/* 保存为当前光标并通知上层 */
static void cursor_set_current(RdpSession *session, const RdpCursorBitmap *bitmap)
{
    if (!session)
        return;

    EnterCriticalSection(&session->lock);
    free(session->cursor_bgra);
    session->cursor_bgra = NULL;
    session->cursor_width = 0;
    session->cursor_height = 0;

    if (bitmap && bitmap->bgra) {
        const size_t bytes = (size_t)bitmap->width * 4 * (size_t)bitmap->height;
        session->cursor_bgra = (uint8_t *)malloc(bytes);
        if (session->cursor_bgra) {
            memcpy(session->cursor_bgra, bitmap->bgra, bytes);
            session->cursor_width = bitmap->width;
            session->cursor_height = bitmap->height;
            session->cursor_hotspot_x = bitmap->hotspot_x;
            session->cursor_hotspot_y = bitmap->hotspot_y;
        }
    }
    session->cursor_visible = 1;
    LeaveCriticalSection(&session->lock);

    emit_event(session, RDP_EV_CURSOR_UPDATE, NULL);
}

/* 从 cacheIndex 取缓存形状并设为当前 */
static void cursor_use_cache(RdpSession *session, UINT16 cache_index)
{
    if (!session || cache_index >= RDP_CURSOR_CACHE_SIZE)
        return;

    EnterCriticalSection(&session->lock);
    const RdpCursorBitmap cached = session->cursor_cache[cache_index];
    RdpCursorBitmap copy = { 0 };
    if (cached.bgra) {
        const size_t bytes = (size_t)cached.width * 4 * (size_t)cached.height;
        copy.bgra = (uint8_t *)malloc(bytes);
        if (copy.bgra) {
            memcpy(copy.bgra, cached.bgra, bytes);
            copy.width = cached.width;
            copy.height = cached.height;
            copy.hotspot_x = cached.hotspot_x;
            copy.hotspot_y = cached.hotspot_y;
        }
    }
    LeaveCriticalSection(&session->lock);

    cursor_set_current(session, copy.bgra ? &copy : NULL);
    free(copy.bgra);
}

/* 把形状写入缓存并设为当前 */
static void cursor_store(RdpSession *session, UINT16 cache_index, int xor_bpp, int width,
                         int height, int hotspot_x, int hotspot_y, const BYTE *xor_mask,
                         UINT32 xor_len, const BYTE *and_mask, UINT32 and_len)
{
    uint8_t *bgra = cursor_decode(xor_bpp, width, height, xor_mask, xor_len, and_mask, and_len);
    if (!bgra)
        return;

    RdpCursorBitmap bitmap = { bgra, width, height, hotspot_x, hotspot_y };

    if (session && cache_index < RDP_CURSOR_CACHE_SIZE) {
        EnterCriticalSection(&session->lock);
        cursor_bitmap_free(&session->cursor_cache[cache_index]);
        session->cursor_cache[cache_index] = bitmap;
        LeaveCriticalSection(&session->lock);
    }

    cursor_set_current(session, &bitmap);
}

static RdpSession *session_from_context(rdpContext *context)
{
    RdpBridgeContext *ctx = (RdpBridgeContext *)context;
    return ctx ? ctx->session : NULL;
}

static BOOL bridge_pointer_position(rdpContext *context,
                                    const POINTER_POSITION_UPDATE *update)
{
    RdpSession *s = session_from_context(context);
    if (!s || !update)
        return TRUE;

    s->pointer_stats.position++;

    /* 服务端主动挪动光标（pointer warp）；常规移动由客户端自己掌握 */
    char buffer[32];
    snprintf(buffer, sizeof(buffer), "%u,%u", (unsigned)update->xPos, (unsigned)update->yPos);
    emit_event(s, RDP_EV_CURSOR_POSITION, buffer);
    return TRUE;
}

static BOOL bridge_pointer_system(rdpContext *context, const POINTER_SYSTEM_UPDATE *update)
{
    RdpSession *s = session_from_context(context);
    if (!s || !update)
        return TRUE;

    s->pointer_stats.system++;

    if (update->type == SYSPTR_NULL) {
        /* 服务端要求隐藏光标 */
        EnterCriticalSection(&s->lock);
        s->cursor_visible = 0;
        LeaveCriticalSection(&s->lock);
        emit_event(s, RDP_EV_CURSOR_UPDATE, NULL);
    } else {
        /* SYSPTR_DEFAULT：客户端应画系统默认箭头；这里保留上一个形状 */
        EnterCriticalSection(&s->lock);
        s->cursor_visible = 1;
        LeaveCriticalSection(&s->lock);
        emit_event(s, RDP_EV_CURSOR_UPDATE, NULL);
    }
    return TRUE;
}

static BOOL bridge_pointer_color(rdpContext *context, const POINTER_COLOR_UPDATE *update)
{
    RdpSession *s = session_from_context(context);
    if (!s || !update)
        return TRUE;

    s->pointer_stats.color++;

    /* 经典彩色光标的 XOR 掩码固定为 1bpp */
    cursor_store(s, update->cacheIndex, 1, update->width, update->height, update->hotSpotX,
                 update->hotSpotY, update->xorMaskData, update->lengthXorMask,
                 update->andMaskData, update->lengthAndMask);
    return TRUE;
}

static BOOL bridge_pointer_new(rdpContext *context, const POINTER_NEW_UPDATE *update)
{
    RdpSession *s = session_from_context(context);
    if (!s || !update)
        return TRUE;

    s->pointer_stats.newCursor++;

    const POINTER_COLOR_UPDATE *color = &update->colorPtrAttr;
    cursor_store(s, color->cacheIndex, (int)update->xorBpp, color->width, color->height,
                 color->hotSpotX, color->hotSpotY, color->xorMaskData, color->lengthXorMask,
                 color->andMaskData, color->lengthAndMask);
    return TRUE;
}

static BOOL bridge_pointer_cached(rdpContext *context, const POINTER_CACHED_UPDATE *update)
{
    RdpSession *s = session_from_context(context);
    if (!s || !update)
        return TRUE;

    s->pointer_stats.cached++;
    cursor_use_cache(s, update->cacheIndex);
    return TRUE;
}

static BOOL bridge_pointer_large(rdpContext *context, const POINTER_LARGE_UPDATE *update)
{
    RdpSession *s = session_from_context(context);
    if (!s || !update)
        return TRUE;

    s->pointer_stats.large++;

    /* 大光标的 XOR 掩码为 32bpp */
    cursor_store(s, update->cacheIndex, 32, update->width, update->height, update->hotSpotX,
                 update->hotSpotY, update->xorMaskData, update->lengthXorMask,
                 update->andMaskData, update->lengthAndMask);
    return TRUE;
}

/* 安装光标回调。返回 TRUE 表示服务端通过独立通道下发光标（需客户端自行绘制）。 */
static void install_pointer_callbacks(freerdp *instance)
{
    if (!instance || !instance->context || !instance->context->update)
        return;

    rdpPointerUpdate *pointer = instance->context->update->pointer;
    if (!pointer)
        return;

    pointer->PointerPosition = bridge_pointer_position;
    pointer->PointerSystem   = bridge_pointer_system;
    pointer->PointerColor    = bridge_pointer_color;
    pointer->PointerNew      = bridge_pointer_new;
    pointer->PointerCached   = bridge_pointer_cached;
    pointer->PointerLarge    = bridge_pointer_large;
}

static BOOL bridge_pre_connect(freerdp *instance)
{
    if (!instance || !instance->context)
        return FALSE;

    /*
     * 通道加载不在这里做：freerdp_connect_begin 在 PreConnect 之后会调用
     * utils_reload_channels() 销毁并重建通道管理器，届时才回调
     * instance->LoadChannels 重新加载。详见 bridge_load_channels 上方说明。
     *
     * 这里只挂 PubSub 订阅 —— 必须在 utils_reload_channels 末尾的
     * freerdp_channels_pre_connect() 触发 ChannelConnected 事件之前完成。
     */
    wPubSub *pubSub = instance->context->pubSub;
    if (pubSub) {
        PubSub_SubscribeChannelConnected(pubSub, bridge_on_channel_connected);
        PubSub_SubscribeChannelDisconnected(pubSub, bridge_on_channel_disconnected);
    }

    return TRUE;
}

static BOOL bridge_post_connect(freerdp *instance)
{
    if (!instance || !instance->context)
        return FALSE;

    /* BGRA32 与 macOS 的 CoreGraphics / Metal 像素布局一致，可零转换上屏 */
    if (!gdi_init(instance, PIXEL_FORMAT_BGRA32))
        return FALSE;

    if (instance->context->update) {
        instance->context->update->EndPaint      = bridge_end_paint;
        instance->context->update->DesktopResize = bridge_desktop_resize;
    }

    install_pointer_callbacks(instance);

    return TRUE;
}

/*
 * 凭据回调。
 * 正常情况下凭据已在 settings 中提供，此回调只在凭据缺失或被拒绝时触发。
 * 返回 FALSE 表示中止连接 —— 应用层应据此上报「用户名或密码错误」，
 * 而不是弹出交互式输入框。
 */
static BOOL bridge_authenticate_ex(freerdp *instance, char **username, char **password,
                                   char **domain, rdp_auth_reason reason)
{
    (void)instance;
    (void)username;
    (void)password;
    (void)domain;
    (void)reason;
    return FALSE;
}

/*
 * 证书校验回调（TOFU）。
 *
 * 信任来源是 FreeRDP 自带的存储：`~/.config/freerdp/server/<host>_<port>.pem`。
 * 已存储的证书不会再触发本回调；证书变化时走 VerifyChangedCertificateEx。
 *
 * 返回值语义（FreeRDP 约定）：
 *   1 = 接受并存储（写入上述文件，后续连接不再询问）
 *   2 = 仅本次会话接受
 *   0 = 拒绝，中止连接
 *
 * 应用层传入的 cert_fingerprint 是「用户已确认过的指纹」：一致则接受并存储；
 * 否则上报 CERT_UNTRUSTED 交给 UI 决策，本次连接中止。
 */
static DWORD bridge_verify_certificate(freerdp *instance, const char *host, UINT16 port,
                                       const char *common_name, const char *subject,
                                       const char *issuer, const char *fingerprint, DWORD flags)
{
    (void)port;
    (void)common_name;
    (void)subject;
    (void)issuer;
    (void)flags;
    (void)host;

    RdpBridgeContext *ctx = (RdpBridgeContext *)instance->context;
    RdpSession       *s   = ctx ? ctx->session : NULL;

    if (!s)
        return 0;

    /* 显式忽略（仅排障用）：接受并存储 */
    if (s->options.ignore_cert)
        return 1;

    /* 用户此前确认过同一指纹：接受并存储 */
    if (s->cert_fingerprint && fingerprint && strcmp(s->cert_fingerprint, fingerprint) == 0)
        return 1;

    emit_event(s, RDP_EV_CERT_UNTRUSTED, fingerprint ? fingerprint : "");
    return 0;
}

/*
 * 证书变化回调 —— 安全关键路径。
 *
 * FreeRDP 存储的证书与当前服务端证书不一致时触发（可能是服务端重装，
 * 也可能是中间人攻击）。一律拒绝并上报，要求用户显式确认后才继续。
 */
static DWORD bridge_verify_changed_certificate(
    freerdp *instance, const char *host, UINT16 port, const char *common_name,
    const char *subject, const char *issuer, const char *new_fingerprint,
    const char *old_subject, const char *old_issuer, const char *old_fingerprint, DWORD flags)
{
    (void)port;
    (void)common_name;
    (void)subject;
    (void)issuer;
    (void)old_subject;
    (void)old_issuer;
    (void)old_fingerprint;
    (void)flags;
    (void)host;

    RdpBridgeContext *ctx = (RdpBridgeContext *)instance->context;
    RdpSession       *s   = ctx ? ctx->session : NULL;

    if (!s)
        return 0;

    if (s->options.ignore_cert)
        return 1;

    /* 用户已确认过这个新指纹（例如刚在 UI 上接受） */
    if (s->cert_fingerprint && new_fingerprint &&
        strcmp(s->cert_fingerprint, new_fingerprint) == 0)
        return 1;

    emit_event(s, RDP_EV_CERT_UNTRUSTED, new_fingerprint ? new_fingerprint : "");
    return 0;
}

/* ------------------------------------------------------------------ */
/* 生命周期                                                             */
/* ------------------------------------------------------------------ */

RdpSession *rdp_session_create(const RdpOptions *options,
                               RdpFrameCallback on_frame,
                               RdpEventCallback on_event,
                               void *user)
{
    if (!options || !options->host || options->host[0] == '\0')
        return NULL;

    RdpSession *session = (RdpSession *)calloc(1, sizeof(RdpSession));
    if (!session)
        return NULL;

    session->options = *options;
    session->host    = bridge_strdup(options->host);
    session->username = bridge_strdup(options->username);
    session->password = bridge_strdup(options->password);
    session->domain   = bridge_strdup(options->domain);
    session->cert_fingerprint = bridge_strdup(options->cert_fingerprint);

    session->on_frame = on_frame;
    session->on_event = on_event;
    session->user     = user;

    if (!session->host)
        goto fail;

    InitializeCriticalSection(&session->lock);
    session->lock_ready = TRUE;

    session->instance = freerdp_new();
    if (!session->instance)
        goto fail;

    /* 使用自定义上下文，便于在回调中反查 RdpSession */
    session->instance->ContextSize = sizeof(RdpBridgeContext);

    session->instance->PreConnect          = bridge_pre_connect;
    session->instance->PostConnect         = bridge_post_connect;
    session->instance->AuthenticateEx      = bridge_authenticate_ex;
    session->instance->VerifyCertificateEx = bridge_verify_certificate;
    session->instance->VerifyChangedCertificateEx = bridge_verify_changed_certificate;
    /* 通道配置加载钩子：utils_reload_channels 会多次回调（含重定向场景） */
    session->instance->LoadChannels        = bridge_load_channels;

    if (!freerdp_context_new(session->instance))
        goto fail;

    ((RdpBridgeContext *)session->instance->context)->session = session;

    if (!apply_settings(session))
        goto fail;

    return session;

fail:
    rdp_session_free(session);
    return NULL;
}

void rdp_session_free(RdpSession *session)
{
    if (!session)
        return;

    if (session->instance) {
        if (session->instance->context)
            freerdp_context_free(session->instance);

        freerdp_free(session->instance);
        session->instance = NULL;
    }

    if (session->lock_ready) {
        DeleteCriticalSection(&session->lock);
        session->lock_ready = FALSE;
    }

    free(session->host);
    free(session->username);
    free(session->password);
    free(session->domain);
    free(session->cert_fingerprint);
    free(session->clipboard_text);

    free(session->cursor_bgra);
    for (size_t i = 0; i < RDP_CURSOR_CACHE_SIZE; ++i)
        cursor_bitmap_free(&session->cursor_cache[i]);

    free(session);
}

/* ------------------------------------------------------------------ */
/* 错误可见                                                             */
/* ------------------------------------------------------------------ */

/*
 * 把 FreeRDP 的 last_error 转成可读描述并通过 RDP_EV_ERROR 上报。
 * 目的：任何连接失败都必须有明确文案，绝不静默黑屏。
 */
static void report_last_error(RdpSession *session, const char *stage)
{
    UINT32 code = 0;
    if (session->instance && session->instance->context)
        code = freerdp_get_last_error(session->instance->context);

    const char *name = freerdp_get_last_error_name(code);
    const char *text = freerdp_get_last_error_string(code);
    const char *cat  = freerdp_get_last_error_category(code);

    /*
     * ERRINFO_* 是服务端给出的**断开原因**，不是客户端故障。
     * 若照搬 stage（如「处理网络事件失败」）会让人误以为是程序出错，
     * 这里改用中性措辞，具体解释交给上层。
     */
    const BOOL serverInitiated = name && (strncmp(name, "ERRINFO_", 8) == 0);

    char buffer[512];
    snprintf(buffer, sizeof(buffer), "%s: [%s] %s (%s)",
             serverInitiated ? "服务端结束了会话" : (stage ? stage : "RDP 错误"),
             name ? name : "UNKNOWN",
             text ? text : "unknown error",
             cat ? cat : "-");

    emit_event(session, RDP_EV_ERROR, buffer);
}

/* ------------------------------------------------------------------ */
/* 连接与事件循环                                                        */
/* ------------------------------------------------------------------ */

int rdp_session_connect(RdpSession *session)
{
    if (!session || !session->instance)
        return -1;

    emit_event(session, RDP_EV_CONNECTING, NULL);

    if (!freerdp_connect(session->instance)) {
        report_last_error(session, "连接失败");
        return -1;
    }

    session->connected_at = time(NULL);
    emit_event(session, RDP_EV_CONNECTED, NULL);
    return 0;
}

int rdp_session_run(RdpSession *session)
{
    if (!session || !session->instance)
        return -1;

    rdpContext *context = session->instance->context;
    if (!context)
        return -1;

    HANDLE handles[MAXIMUM_WAIT_OBJECTS];
    int    result = 0;

    for (;;) {
        if (InterlockedCompareExchange(&session->stop_requested, 0, 0) != 0)
            break;
        if (freerdp_shall_disconnect_context(context))
            break;

        const DWORD count = freerdp_get_event_handles(context, handles, MAXIMUM_WAIT_OBJECTS);
        if (count == 0) {
            report_last_error(session, "获取事件句柄失败");
            result = -1;
            break;
        }

        const DWORD status = WaitForMultipleObjects(count, handles, FALSE, 100);
        if (status == WAIT_FAILED) {
            report_last_error(session, "等待网络事件失败");
            result = -1;
            break;
        }

        /*
         * 被要求停止时立即退出，不再触碰上下文。
         * 否则可能在已断开的上下文上调用 check_event_handles，产生假错误。
         */
        if (InterlockedCompareExchange(&session->stop_requested, 0, 0) != 0)
            break;

        if (!freerdp_check_event_handles(context)) {
            report_last_error(session, "处理网络事件失败");
            result = -1;
            break;
        }

        /*
         * 「已连接但无画面」检测 —— 把黑屏显式化。
         * 只上报一次，避免刷屏。
         */
        if (InterlockedCompareExchange(&session->frame_count, 0, 0) == 0 &&
            InterlockedCompareExchange(&session->no_frame_reported, 0, 0) == 0 &&
            session->connected_at > 0 &&
            (time(NULL) - session->connected_at) >= RDP_NO_FRAME_TIMEOUT_SECONDS)
        {
            InterlockedExchange(&session->no_frame_reported, 1);
            emit_event(session, RDP_EV_ERROR,
                       "已连接但未收到任何画面：请确认服务端 gnome-remote-desktop 版本，"
                       "以及客户端是否完整宣告了 GFX 图形管线与 H.264 能力");
        }
    }

    /*
     * 断开必须在事件循环线程上执行。
     * FreeRDP 的连接/断开是有状态且非线程安全的，从 UI 线程直接调用
     * freerdp_disconnect 会在随后的 freerdp_context_free 阶段导致进程 abort。
     * 因此 rdp_session_disconnect 只置标志，实际断开由这里完成。
     */
    if (!freerdp_shall_disconnect_context(context))
        freerdp_disconnect(session->instance);

    emit_event(session, RDP_EV_DISCONNECTED, NULL);
    return result;
}

void rdp_session_disconnect(RdpSession *session)
{
    if (!session)
        return;

    /*
     * 仅请求停止。事件循环最多 100ms 内退出并自行执行 freerdp_disconnect，
     * 保证断开与连接在同一线程上。
     */
    InterlockedExchange(&session->stop_requested, 1);
}

/* ------------------------------------------------------------------ */
/* 输入注入                                                             */
/* ------------------------------------------------------------------ */

/*
 * 输入函数可能从 UI 线程调用，而 FreeRDP 只允许在其事件循环线程上操作。
 * 这里统一用会话锁串行化。FreeRDP 事件循环不会长时间持锁，
 * 因此锁竞争可忽略；未连接时安全丢弃事件。
 */
static rdpInput *session_input(RdpSession *session)
{
    if (!session || !session->instance || !session->instance->context)
        return NULL;
    return session->instance->context->input;
}

void rdp_send_mouse_move(RdpSession *session, uint16_t x, uint16_t y)
{
    if (!session || !session->lock_ready)
        return;

    EnterCriticalSection(&session->lock);
    rdpInput *input = session_input(session);
    if (input)
        freerdp_input_send_mouse_event(input, PTR_FLAGS_MOVE, x, y);
    LeaveCriticalSection(&session->lock);
}

void rdp_send_mouse_button(RdpSession *session, int button, bool down, uint16_t x, uint16_t y)
{
    if (!session || !session->lock_ready)
        return;

    UINT16 flags;
    switch (button) {
        case RDP_MOUSE_LEFT:   flags = PTR_FLAGS_BUTTON1; break;
        case RDP_MOUSE_RIGHT:  flags = PTR_FLAGS_BUTTON2; break;
        case RDP_MOUSE_MIDDLE: flags = PTR_FLAGS_BUTTON3; break;
        default:               return;
    }
    if (down)
        flags |= PTR_FLAGS_DOWN;

    EnterCriticalSection(&session->lock);
    rdpInput *input = session_input(session);
    if (input)
        freerdp_input_send_mouse_event(input, flags, x, y);
    LeaveCriticalSection(&session->lock);
}

void rdp_send_mouse_wheel(RdpSession *session, int delta, uint16_t x, uint16_t y)
{
    (void)x;
    (void)y;

    if (!session || !session->lock_ready)
        return;

    /*
     * RDP 滚轮事件的 x 字段承载「旋转量」而非坐标：一格 = 120。
     * 本 API 的 delta 单位为格，正值表示向上/向左。
     */
    int steps = delta * 120;
    UINT16 flags = PTR_FLAGS_WHEEL;
    if (steps < 0) {
        flags |= PTR_FLAGS_WHEEL_NEGATIVE;
        steps = -steps;
    }
    if (steps > 0xFF)
        steps = 0xFF;

    EnterCriticalSection(&session->lock);
    rdpInput *input = session_input(session);
    if (input)
        freerdp_input_send_mouse_event(input, flags, (UINT16)steps, 0);
    LeaveCriticalSection(&session->lock);
}

/*
 * scancode 约定：低 8 位为 PS/2 扫描码，bit 0x0100 置位表示扩展键
 * （如 Delete、方向键、右侧 Ctrl/Alt）。
 */
void rdp_send_key_scancode(RdpSession *session, uint16_t scancode, bool down)
{
    if (!session || !session->lock_ready)
        return;

    UINT16 flags = down ? 0 : KBD_FLAGS_RELEASE;
    if (scancode & 0x0100)
        flags |= KBD_FLAGS_EXTENDED;

    EnterCriticalSection(&session->lock);
    rdpInput *input = session_input(session);
    if (input)
        freerdp_input_send_keyboard_event(input, flags, (UINT8)(scancode & 0x00FF));
    LeaveCriticalSection(&session->lock);
}

void rdp_send_unicode_char(RdpSession *session, uint16_t codepoint, bool down)
{
    if (!session || !session->lock_ready)
        return;

    const UINT16 flags = down ? 0 : KBD_FLAGS_RELEASE;

    EnterCriticalSection(&session->lock);
    rdpInput *input = session_input(session);
    if (input)
        freerdp_input_send_unicode_keyboard_event(input, flags, codepoint);
    LeaveCriticalSection(&session->lock);
}

void rdp_send_ctrl_alt_del(RdpSession *session)
{
    if (!session || !session->lock_ready)
        return;

    static const struct {
        UINT16 scancode;
        BOOL   extended;
    } keys[] = {
        { 0x1D, FALSE }, /* 左 Ctrl */
        { 0x38, FALSE }, /* 左 Alt  */
        { 0x53, TRUE  }, /* Delete（扩展键） */
    };
    const size_t count = sizeof(keys) / sizeof(keys[0]);

    EnterCriticalSection(&session->lock);
    rdpInput *input = session_input(session);
    if (input) {
        for (size_t i = 0; i < count; ++i) {
            const UINT16 flags = keys[i].extended ? KBD_FLAGS_EXTENDED : 0;
            freerdp_input_send_keyboard_event(input, flags, (UINT8)keys[i].scancode);
        }
        for (size_t i = count; i-- > 0;) {
            const UINT16 flags =
                KBD_FLAGS_RELEASE | (keys[i].extended ? KBD_FLAGS_EXTENDED : 0);
            freerdp_input_send_keyboard_event(input, flags, (UINT8)keys[i].scancode);
        }
    }
    LeaveCriticalSection(&session->lock);
}

/*
 * 请求服务端调整分辨率。
 *
 * **必须走 disp 动态通道**（Microsoft::Windows::RDS::DisplayControl）。
 *
 * 曾经的错误做法：调用 freerdp_display_send_monitor_layout()。它发的是
 * DATA_PDU_TYPE_MONITOR_LAYOUT —— 属于**连接时序**的 PDU，规范上只应在
 * 响应服务端 Deactivate All 时发送。在会话中途主动发属于协议非法，
 * gnome-remote-desktop 会判定为会话需要重初始化并直接登出。
 * 实测：启用该调用 4/4 次被登出（ERRINFO_LOGOFF_BY_USER），
 *       跳过该调用 4/4 次正常。
 *
 * 正确路径由 gnome-remote-desktop 支持：通过 disp 通道下发 monitor layout，
 * 服务端处理后经 GFX ResetGraphics 回传新尺寸（触发 DesktopResize 回调）。
 * 因此这里**不改本地 settings**，尺寸以服务端回传为准。
 */
void rdp_request_resize(RdpSession *session, int width, int height)
{
    if (!session || !session->lock_ready || width <= 0 || height <= 0)
        return;

    EnterCriticalSection(&session->lock);

    DispClientContext *disp = session->disp;
    if (!disp || !disp->SendMonitorLayout) {
        LeaveCriticalSection(&session->lock);
        return;
    }

    DISPLAY_CONTROL_MONITOR_LAYOUT layout = { 0 };
    layout.Flags              = DISPLAY_CONTROL_MONITOR_PRIMARY;
    layout.Left               = 0;
    layout.Top                = 0;
    layout.Width              = (UINT32)width;
    layout.Height             = (UINT32)height;
    layout.PhysicalWidth      = (UINT32)width;
    layout.PhysicalHeight     = (UINT32)height;
    layout.Orientation        = 0; /* 横向 */
    layout.DesktopScaleFactor = 100;
    layout.DeviceScaleFactor  = 100;

    disp->SendMonitorLayout(disp, 1, &layout);

    LeaveCriticalSection(&session->lock);
}

void rdp_send_clipboard_text(RdpSession *session, const char *utf8)
{
    if (!session || !session->lock_ready)
        return;

    /* 超大内容直接丢弃，避免拖垮通道 */
    if (utf8 && strlen(utf8) > RDP_CLIPBOARD_MAX_BYTES)
        return;

    EnterCriticalSection(&session->lock);
    free(session->clipboard_text);
    session->clipboard_text = utf8 ? bridge_strdup(utf8) : NULL;
    LeaveCriticalSection(&session->lock);

    /* 宣告本地剪贴板已有新内容，服务端需要时会来取 */
    bridge_cliprdr_advertise_text(session);
}

/* ------------------------------------------------------------------ */
/* 自检                                                                 */
/* ------------------------------------------------------------------ */

uint8_t *rdp_session_copy_cursor(RdpSession *session, RdpCursorInfo *info)
{
    if (info)
        memset(info, 0, sizeof(*info));

    if (!session || !session->lock_ready)
        return NULL;

    EnterCriticalSection(&session->lock);

    if (info) {
        info->width = session->cursor_width;
        info->height = session->cursor_height;
        info->hotspot_x = session->cursor_hotspot_x;
        info->hotspot_y = session->cursor_hotspot_y;
        info->visible = session->cursor_visible;
    }

    uint8_t *copy = NULL;
    if (session->cursor_bgra && session->cursor_width > 0 && session->cursor_height > 0) {
        const size_t bytes = (size_t)session->cursor_width * 4 * (size_t)session->cursor_height;
        copy = (uint8_t *)malloc(bytes);
        if (copy)
            memcpy(copy, session->cursor_bgra, bytes);
    }

    LeaveCriticalSection(&session->lock);
    return copy;
}

void rdp_session_pointer_stats(RdpSession *session, RdpPointerStats *out)
{
    if (!out)
        return;

    if (!session || !session->lock_ready) {
        memset(out, 0, sizeof(*out));
        return;
    }

    EnterCriticalSection(&session->lock);
    *out = session->pointer_stats;
    LeaveCriticalSection(&session->lock);
}

const char *rdp_bridge_freerdp_version(void)
{
    return freerdp_get_version_string();
}

const char *rdp_bridge_build_config(void)
{
    return freerdp_get_build_config();
}
