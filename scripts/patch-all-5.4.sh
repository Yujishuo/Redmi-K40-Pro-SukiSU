#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 把 SukiSU-Ultra main 分支移植到 AGNi 5.4.302 内核所需的全部源码补丁。
#
# 从 wsl-build.sh 里抽出来的，逻辑完全一致，但不再依赖 /mnt/e、/root 这些
# WSL 专有路径，因此本地和 GitHub Actions 可以共用同一份。
#
# 用法:
#   bash scripts/patch-all-5.4.sh <内核源码根目录> [KernelSU 目录名]
# 例:
#   bash scripts/patch-all-5.4.sh ./kernel
#   bash scripts/patch-all-5.4.sh ./kernel KernelSU
#
# 幂等：每段补丁都有 grep 守卫，重复执行不会叠加。
# 前置条件: 已在 <内核根> 下用官方 setup.sh 集成好 SukiSU（存在 KernelSU/kernel）。
# ---------------------------------------------------------------------------
set -euo pipefail

KDIR="${1:?用法: bash scripts/patch-all-5.4.sh <内核源码根目录> [KernelSU 目录名]}"
KS="${2:-KernelSU}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$KDIR"

[ -d "$KS/kernel" ] || { echo "错误: $KDIR/$KS/kernel 不存在，请先执行官方 setup.sh 集成"; exit 1; }

say() { echo "[patch-5.4] $*"; }

# ---------------------------------------------------------------------------
# 1. linux/pgtable.h 在 5.8 才引入，5.4 要退回 asm/pgtable.h
# ---------------------------------------------------------------------------
for f in $(grep -rl "linux/pgtable.h" "$KS/kernel" 2>/dev/null || true); do
  if ! grep -q "KERNEL_VERSION(5, 8, 0)" "$f"; then
    sed -i 's|#include <linux/pgtable.h>|#include <linux/version.h>\n#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 8, 0)\n#include <linux/pgtable.h>\n#else\n#include <asm/pgtable.h>\n#endif|' "$f"
    say "patched: $f (pgtable.h 5.8+)"
  fi
done

# ---------------------------------------------------------------------------
# 2. security_inode_init_security_anon 在 5.10 才加入，5.4 上跳过 LSM 标注
# ---------------------------------------------------------------------------
FW="$KS/kernel/infra/file_wrapper.c"
if [ -f "$FW" ] && grep -q "security_inode_init_security_anon" "$FW" && \
   ! grep -q "KERNEL_VERSION(5, 10, 0)" "$FW"; then
python3 - "$FW" <<'PYE'
import sys, io
p = sys.argv[1]
s = io.open(p).read()
old = """    error = security_inode_init_security_anon(inode, &qname, context_inode);
    if (error) {
        iput(inode);
        return ERR_PTR(error);
    }"""
new = """#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)
    error = security_inode_init_security_anon(inode, &qname, context_inode);
    if (error) {
        iput(inode);
        return ERR_PTR(error);
    }
#else
    error = 0;
#endif"""
assert old in s, "file_wrapper.c: pattern not found"
io.open(p, "w").write(s.replace(old, new, 1))
PYE
  say "patched: file_wrapper.c (security_inode_init_security_anon 5.10+)"
fi

# ---------------------------------------------------------------------------
# 3. 5.4 没有 __p4d_to_phys，禁用 P4D 大页分支
# ---------------------------------------------------------------------------
PM="$KS/kernel/hook/arm64/patch_memory.c"
if [ -f "$PM" ] && ! grep -q "defined(p4d_leaf) && LINUX_VERSION_CODE" "$PM"; then
  grep -q "linux/version.h" "$PM" || sed -i 's|#include "../patch_memory.h"|#include <linux/version.h>\n#include "../patch_memory.h"|' "$PM"
  sed -i 's/#if defined(p4d_leaf)/#if defined(p4d_leaf) \&\& LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)/' "$PM"
  say "patched: patch_memory.c (no __p4d_to_phys)"
fi

# ---------------------------------------------------------------------------
# 4. 5.4 没有 seccomp filter cache（5.9+），这两个函数降级为 no-op
# ---------------------------------------------------------------------------
SC="$KS/kernel/infra/seccomp_cache.c"
if [ -f "$SC" ] && ! grep -q "KERNEL_VERSION(5, 9, 0)" "$SC"; then
  sed -i 's|#include "infra/seccomp_cache.h"|#include "infra/seccomp_cache.h"\n\n#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 9, 0)\nstruct seccomp_filter;\nvoid ksu_seccomp_clear_cache(struct seccomp_filter *filter, int nr) { (void)filter; (void)nr; }\nvoid ksu_seccomp_allow_cache(struct seccomp_filter *filter, int nr) { (void)filter; (void)nr; }\n#else|' "$SC"
  printf '\n#endif /* LINUX_VERSION_CODE < 5.9.0 */\n' >> "$SC"
  say "patched: seccomp_cache.c (no seccomp cache)"
fi

# ---------------------------------------------------------------------------
# 5. 5.4 的 fsnotify 是 handle_event，pkg_observer 用了 6.x 的
#    handle_inode_event，整体降级为 no-op
#    → 这也是管理器 appid 需要靠 service.d 脚本兜底的原因（见 README 第九、十章）
# ---------------------------------------------------------------------------
PO="$KS/kernel/manager/pkg_observer.c"
if [ -f "$PO" ] && ! grep -q "KERNEL_VERSION(5, 9, 0)" "$PO"; then
  sed -i '1i #include <linux/version.h>\n#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 9, 0)\n#include "manager/manager_observer.h"\nint ksu_observer_init(void) { return 0; }\nvoid ksu_observer_exit(void) { }\n#else' "$PO"
  printf '\n#endif\n' >> "$PO"
  say "patched: pkg_observer.c (fsnotify 5.9+)"
fi

# ---------------------------------------------------------------------------
# 6. 5.4 的 task_work_add 用 bool，没有 TWA_RESUME；put_task_struct 需要 sched/task.h
# ---------------------------------------------------------------------------
AL="$KS/kernel/policy/allowlist.c"
if [ -f "$AL" ] && ! grep -q "KSU_TWA_COMPAT" "$AL"; then
  sed -i '1i #include <linux/version.h>\n#include <linux/sched/task.h>\n#define KSU_TWA_COMPAT 1\n#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 9, 0)\n#define TWA_RESUME true\n#endif' "$AL"
  say "patched: allowlist.c (TWA_RESUME)"
fi

# ---------------------------------------------------------------------------
# 7. clocksource->vdso_clock_mode 在 5.5 才加入
# ---------------------------------------------------------------------------
CS="$KS/kernel/extension/cpu_spoof.c"
if [ -f "$CS" ] && ! grep -q "KERNEL_VERSION(5, 5, 0)" "$CS"; then
python3 - "$CS" <<'PYE'
import sys, io
p = sys.argv[1]
lines = io.open(p).read().split("\n")
out, i = [], 0
while i < len(lines):
    if "vdso_clock_mode" in lines[i] and "curr_cs_ptr" in lines[i]:
        out.append("#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 5, 0)")
        out.append(lines[i]); out.append(lines[i + 1])
        out.append("#endif")
        i += 2
        continue
    out.append(lines[i]); i += 1
io.open(p, "w").write("\n".join(out))
PYE
  say "patched: cpu_spoof.c (vdso_clock_mode 5.5+)"
fi

# ---------------------------------------------------------------------------
# 8. dispatch.c 缺 init_task / tasklist_lock 等头
# ---------------------------------------------------------------------------
DP="$KS/kernel/supercall/dispatch.c"
if [ -f "$DP" ] && ! grep -q "KSU_DISPATCH_COMPAT" "$DP"; then
  sed -i '1i #include <linux/sched/signal.h>\n#include <linux/sched/task.h>\n#include <linux/init_task.h>\n#define KSU_DISPATCH_COMPAT 1' "$DP"
  say "patched: dispatch.c (missing headers)"
fi

# ---------------------------------------------------------------------------
# 9. SELinux 子系统 + 其余零散补丁（rules.c / sepolicy.c / selinux_hide.c /
#    su_mount_ns.c / app_profile.c / apk_sign.c）
#    KSU_PATCH_BOOT_EVENT 默认关闭：5.4 上把 on_boot_completed 改成
#    track_throne(false) 会同步全量扫 /data/app，实测导致无法开机。
#    改用 scripts/ksu-manager-appid.sh 走 service.d 持久化 appid。
# ---------------------------------------------------------------------------
KSU_SRC="$KS/kernel" KSU_PATCH_BOOT_EVENT="${KSU_PATCH_BOOT_EVENT:-0}" \
  python3 "$SELF_DIR/patch-sukisu-5.4.py"

# ---------------------------------------------------------------------------
# 10. defconfig
#     这一段必须完全幂等：先把本脚本管理过的行全部删掉，再统一追加一次。
#     （早期版本只删 CONFIG_KSU 几行，重复执行会把整块配置叠加成两份）
# ---------------------------------------------------------------------------
DEF=arch/arm64/configs/agni_haydn_defconfig
if [ -f "$DEF" ]; then
  sed -i -E \
    -e '/^CONFIG_KSU=/d' \
    -e '/^# CONFIG_KSU_DEBUG is not set$/d' \
    -e '/^# CONFIG_WERROR is not set$/d' \
    -e '/^# CONFIG_BPF_PRELOAD is not set$/d' \
    -e '/^CONFIG_MODVERSIONS=/d' \
    -e '/^CONFIG_ASM_MODVERSIONS=/d' \
    -e '/^# CONFIG_MODVERSIONS is not set$/d' \
    -e '/^CONFIG_KPM=/d' \
    -e '/^# CONFIG_KPM is not set$/d' \
    -e '/^# ---- KernelSU build options/d' \
    -e '/^# ---- end ----$/d' \
    "$DEF"

  {
    echo
    echo "# ---- KernelSU build options (managed by patch-all-5.4.sh) ----"
    echo "CONFIG_KSU=y"
    echo "# CONFIG_KSU_DEBUG is not set"
    echo "# CONFIG_WERROR is not set"
    echo "# CONFIG_BPF_PRELOAD is not set"
    # 5.4 + clang-18/LTO/lld：genksyms 生成的 __crc_* 解析不了，链接会报
    # "relocation R_AARCH64_ABS32 cannot be used against symbol '__crc_...'"。
    # 本机型所有驱动都编进内核、不加载外部模块，关掉 MODVERSIONS 无副作用。
    echo "# CONFIG_MODVERSIONS is not set"
    # KPM: SukiSU 的内核补丁模块加载器（运行时加载 .kpm）。
    # 依赖 KALLSYMS / KALLSYMS_ALL，Kconfig 会自动 select。
    # 不想要就把环境变量 KSU_KPM 设为 0。
    if [ "${KSU_KPM:-1}" = "1" ]; then
      echo "CONFIG_KPM=y"
    fi
    echo "# ---- end ----"
  } >> "$DEF"

  say "defconfig 已调整: CONFIG_KSU=y / KPM=${KSU_KPM:-1} / MODVERSIONS off / WERROR off"
else
  say "警告: 未找到 $DEF，跳过 defconfig 调整"
fi

say "全部补丁完成"
