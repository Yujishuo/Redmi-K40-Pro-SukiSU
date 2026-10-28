#!/system/bin/sh
# ---------------------------------------------------------------------------
# SukiSU 管理器自动加冕（Redmi K40 Pro / haydn / 5.4.302 AGNi）
#
# 背景：5.4 内核没有 fsnotify 的 handle_inode_event 回调，SukiSU 的
# pkg_observer 被降级为 no-op；core/init.c 里真正的 track_throne(false)
# 只在 late-load 分支执行；正常启动路径只走到 on_boot_completed 的
# track_throne(true)（prune_only，不加冕）。
# 结果：ksu_manager_appid 每次开机都是 -1 -> is_uid_manager() 恒假 ->
# 内核在 zygote setresuid 时不给管理器装 fd -> 管理器显示"不支持/预览模式"。
#
# 这里在 service 阶段把 appid 写进模块参数。注意 appid 是 uid % 100000，
# 管理器真实 uid 为 10303（进程名 u0_a303 里的 303 是 appId-10000，不是 uid）。
# ---------------------------------------------------------------------------

PARAM=/sys/module/kernelsu/parameters/ksu_debug_manager_appid
PKG=com.sukisu.ultra

[ -w "$PARAM" ] || exit 0

# 内核里是 uid_t（无符号），-1 会显示成 4294967295
cur=$(cat "$PARAM" 2>/dev/null)
[ "$cur" = "4294967295" ] || [ "$cur" = "-1" ] || exit 0

appid=""
for i in 1 2 3 4 5 6 7 8 9 10; do
    uid=$(dumpsys package "$PKG" 2>/dev/null | sed -n 's/.*appId=\([0-9]\{1,\}\).*/\1/p' | head -n 1)
    if [ -n "$uid" ]; then
        appid=$((uid % 100000))
        break
    fi
    sleep 2
done

# dumpsys 还没就绪时的兜底值（本机实测）
[ -n "$appid" ] || appid=10303

echo "$appid" > "$PARAM"
