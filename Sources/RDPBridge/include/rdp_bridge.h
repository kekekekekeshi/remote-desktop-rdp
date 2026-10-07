/*
 * RDPBridge —— libfreerdp 的唯一接触面。
 *
 * 设计原则：
 *   - 只暴露朴素 C ABI（结构体 + 函数指针回调），不引入 C++ / ObjC++
 *   - Swift 侧永远不直接触碰 freerdp 类型
 *   - 所有 freerdp 调用都发生在单一后台线程（FreeRDP 非线程安全）
 *
 * 事件与帧回调均从 FreeRDP 事件循环线程触发；
 * Swift 侧必须在回调内立即拷贝需要跨线程的数据，且不得做重活。
 */
#ifndef RDP_BRIDGE_H
#define RDP_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RdpSession RdpSession;

/* ---------------- 事件类型（RdpEventCallback 的 event 参数） ---------------- */
enum {
    RDP_EV_CONNECTING      = 1, /* 已发起连接，尚未完成握手 */
    RDP_EV_CONNECTED       = 2, /* 握手完成，会话已激活 */
    RDP_EV_DISCONNECTED    = 3, /* 会话结束（正常断开或远端关闭） */
    RDP_EV_ERROR           = 4, /* message 为可读错误描述 */
    RDP_EV_CERT_UNTRUSTED  = 5, /* message 为证书指纹（sha256），需用户决定是否信任 */
    RDP_EV_CLIPBOARD_TEXT  = 6, /* message 为远端剪贴板文本（UTF-8） */
    RDP_EV_DESKTOP_RESIZE  = 7, /* message 为 "宽x高"，远端分辨率已变化 */
    RDP_EV_CURSOR_UPDATE   = 8, /* 光标形状变化；用 rdp_session_copy_cursor 取新形状 */
    RDP_EV_CURSOR_POSITION = 9, /* 服务端主动移动光标；message 为 "x,y" */
};

/*
 * 光标形状。
 *
 * RDP 的分工：**服务端只下发光标形状，位置与绘制由客户端负责**。
 * 位置之所以由客户端掌握，是因为绝大多数移动都源自客户端自己的鼠标输入；
 * 服务端只在自己主动挪动光标（pointer warp）时下发 RDP_EV_CURSOR_POSITION。
 */
typedef struct {
    int width;     /* 位图宽（像素） */
    int height;    /* 位图高（像素） */
    int hotspot_x; /* 热点相对左上角 */
    int hotspot_y;
    int visible;   /* 0 表示光标应隐藏（服务端置空光标） */
} RdpCursorInfo;

/*
 * 取当前光标位图的堆副本：BGRA32、**预乘 alpha**，长度为 width*height*4。
 * 调用方负责 free()。无光标时返回 NULL 并把 *info 清零。
 */
uint8_t *rdp_session_copy_cursor(RdpSession *session, RdpCursorInfo *info);

/* ---------------- 鼠标按键（rdp_send_mouse_button 的 button 参数） ---------------- */
enum {
    RDP_MOUSE_LEFT   = 1,
    RDP_MOUSE_MIDDLE = 2,
    RDP_MOUSE_RIGHT  = 3,
};

/*
 * 连接参数。
 *
 * 注意：username / password 是 **RDP 凭据**（在 Ubuntu 端
 * 「设置 → 系统 → 远程桌面 → 远程登录」中单独设置的那一组），
 * 不是 Linux 系统账号密码。二者在 gnome-remote-desktop 中是两套东西：
 * NLA 阶段校验 RDP 凭据，进入 GDM 登录页后才使用 Linux 系统密码。
 *
 * 所有字符串指针只需在 rdp_session_create 调用期间有效，内部会深拷贝。
 */
typedef struct {
    const char *host;             /* 必填，如 "192.168.1.5" */
    int         port;             /* 0 表示使用默认 3389 */
    const char *username;         /* RDP 凭据用户名 */
    const char *password;         /* RDP 凭据密码 */
    const char *domain;           /* 可为 NULL */
    int         width;            /* 0 表示默认 1024 */
    int         height;           /* 0 表示默认 768 */
    int         color_depth;      /* 0 表示默认 32 */
    bool        dynamic_resolution; /* 请求远端随窗口尺寸调整分辨率 */
    bool        clipboard;        /* 启用剪贴板重定向 */
    bool        ignore_cert;      /* 忽略证书校验（仅尖刺/排障用，正式流程应走 TOFU） */
    const char *cert_fingerprint; /* 已信任的证书指纹；NULL 表示尚未信任 */
} RdpOptions;

/*
 * 帧回调：BGRA32 像素，stride 为字节步长。
 * dirty 矩形描述本次更新的区域，(0,0,width,height) 表示全屏。
 * bgra 指向的缓冲区在回调返回后即失效，调用方如需保留必须自行拷贝。
 */
typedef void (*RdpFrameCallback)(const uint8_t *bgra, int width, int height, int stride,
                                 int dirty_x, int dirty_y, int dirty_w, int dirty_h,
                                 void *user);

/* 事件回调：message 在回调期间有效，如需保留必须自行拷贝 */
typedef void (*RdpEventCallback)(int event, const char *message, void *user);

/*
 * 光标更新统计。
 *
 * 用途：判断服务端是把光标**合成进画面**，还是通过独立的 Pointer 通道下发。
 * 前者无需客户端处理；后者要求客户端自己把光标画到帧上，否则用户看不到鼠标指针。
 * 各项计数均为 0 表示服务端走的是合成路径。
 */
typedef struct {
    unsigned int position;  /* 位置更新 */
    unsigned int system;    /* 系统光标（默认箭头 / 隐藏） */
    unsigned int color;     /* 彩色光标位图（AND/XOR 掩码） */
    unsigned int newCursor; /* 新版彩色光标（带 xorBpp） */
    unsigned int cached;    /* 命中光标缓存 */
    unsigned int large;     /* 大光标 */
} RdpPointerStats;

/* 读取光标更新统计。线程安全。 */
void rdp_session_pointer_stats(RdpSession *session, RdpPointerStats *out);

/* ---------------- 生命周期 ---------------- */

/*
 * 创建会话。成功返回非 NULL，失败返回 NULL。
 * 只做参数装配，不发起网络连接。
 */
RdpSession *rdp_session_create(const RdpOptions *options,
                               RdpFrameCallback on_frame,
                               RdpEventCallback on_event,
                               void *user);

/* 释放会话。内部会先确保事件循环已停止。传 NULL 安全。 */
void rdp_session_free(RdpSession *session);

/* ---------------- 连接 ---------------- */

/*
 * 建立连接（含 TLS 与 NLA/CredSSP 握手）。阻塞，需在后台线程调用。
 * 返回 0 表示成功，非 0 表示失败（详情通过 RDP_EV_ERROR 上报）。
 */
int rdp_session_connect(RdpSession *session);

/*
 * 运行事件循环，直到断开或调用 rdp_session_disconnect。阻塞，需在后台线程调用。
 * 返回 0 表示正常结束。
 */
int rdp_session_run(RdpSession *session);

/* 请求退出事件循环。线程安全，可从任意线程调用。 */
void rdp_session_disconnect(RdpSession *session);

/* ---------------- 输入（全部线程安全） ---------------- */

void rdp_send_mouse_move(RdpSession *session, uint16_t x, uint16_t y);
void rdp_send_mouse_button(RdpSession *session, int button, bool down, uint16_t x, uint16_t y);
void rdp_send_mouse_wheel(RdpSession *session, int delta, uint16_t x, uint16_t y);
void rdp_send_key_scancode(RdpSession *session, uint16_t scancode, bool down);
void rdp_send_unicode_char(RdpSession *session, uint16_t codepoint, bool down);
void rdp_send_ctrl_alt_del(RdpSession *session);
void rdp_send_clipboard_text(RdpSession *session, const char *utf8);
void rdp_request_resize(RdpSession *session, int width, int height);

/* ---------------- 自检 ---------------- */

/* 底层 libfreerdp 的版本字符串（真实符号调用，可证明动态库已正确链接） */
const char *rdp_bridge_freerdp_version(void);

/*
 * libfreerdp 的编译期配置串（形如 "WITH_FFMPEG=ON WITH_GFX_H264=ON ..."）。
 * 用于启动自检：连接 gnome-remote-desktop 要求客户端具备 GFX 与 H.264 能力，
 * 构建缺失时应尽早明确提示，而不是让用户对着黑屏排查。
 */
const char *rdp_bridge_build_config(void);

#ifdef __cplusplus
}
#endif

#endif /* RDP_BRIDGE_H */
