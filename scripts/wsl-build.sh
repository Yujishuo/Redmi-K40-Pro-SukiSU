#!/bin/bash
# 在 WSL Ubuntu-24.04 内编译 haydn(SM8350) 内核：AGNi 树 + SukiSU
# 用法: wsl -d Ubuntu-24.04 -u root -- bash /root/build.sh [main|builtin]
set -euo pipefail

MODE="${1:-main}"
LOG=/root/build.log
exec > >(tee -a "$LOG") 2>&1
echo "===== $(date) 开始，SukiSU 模式: $MODE ====="

export DEBIAN_FRONTEND=noninteractive

step() { echo; echo "===== $* ====="; }

step "1/7 安装依赖"
apt-get update -qq
apt-get install -y -qq \
  bc bison build-essential flex libssl-dev libelf-dev python3 python3-pip \
  git curl ca-certificates zip unzip xz-utils cpio rsync \
  gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu \
  gcc-arm-linux-gnueabi binutils-arm-linux-gnueabi device-tree-compiler \
  clang-18 lld-18 llvm-18 lz4 zstd ccache

step "2/7 配置 swap（当前内存只有 5G）"
if ! swapon --show | grep -q /swapfile; then
  if [ ! -f /swapfile ]; then
    fallocate -l 12G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=12288
  fi
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
fi
free -g | head -3

step "3/7 拉取 AGNi haydn 内核源码"
mkdir -p /root/haydn
cd /root/haydn
if [ ! -f kernel/Makefile ]; then
  rm -rf kernel
  ok=0
  for try in 1 2 3; do
    rm -f kernel.tar.gz
    echo "下载内核源码（第 $try 次）..."
    if curl -L --retry 3 --max-time 3600 --no-progress-meter -o kernel.tar.gz \
        https://codeload.github.com/psndna88/AGNi_pureMIUI/tar.gz/refs/heads/AGNi_haydn_MIUI_ST \
        && gzip -t kernel.tar.gz 2>/dev/null; then
      ok=1; break
    fi
    echo "第 $try 次下载不完整，重试"
  done
  [ "$ok" = 1 ] || { echo "内核源码下载失败"; exit 1; }
  echo "压缩包大小: $(du -h kernel.tar.gz | cut -f1)"
  mkdir -p kernel
  tar -xzf kernel.tar.gz -C kernel --strip-components=1
fi
cd kernel
head -4 Makefile

step "4/7 集成 SukiSU ($MODE)"
if [ -e drivers/kernelsu/Kbuild ] || [ -e KernelSU/kernel/Kbuild ]; then
  echo "已集成过，跳过"
else
rm -rf drivers/kernelsu KernelSU
curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" | bash -s "$MODE" || {
  echo "setup.sh 失败，改用镜像方式手工集成"
  curl -L --retry 3 -o /root/haydn/sukisu.tar.gz \
    "https://codeload.github.com/SukiSU-Ultra/SukiSU-Ultra/tar.gz/refs/heads/$MODE"
  rm -rf KernelSU && mkdir KernelSU
  tar -xzf /root/haydn/sukisu.tar.gz -C KernelSU --strip-components=1
  ln -sfn ../KernelSU/kernel drivers/kernelsu
  grep -q kernelsu drivers/Makefile || echo 'obj-$(CONFIG_KSU) += kernelsu/' >> drivers/Makefile
  grep -q 'drivers/kernelsu/Kconfig' drivers/Kconfig || sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig
}
fi
echo "驱动目录:"; ls -l drivers/kernelsu | head -3
echo "SukiSU 版本: $(grep -m1 KSU_VERSION kernel/include/ksu.h 2>/dev/null || true)"

step "4.5/7 兼容性修补（5.4 内核 + AGNi 工具链前缀）"
# AGNi 的 Makefile 假定 $(CROSS_COMPILE)llvm-* 存在，补上带前缀的软链接
for t in clang clang++ ld.lld llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-readelf llvm-size llvm-strip; do
  src="/usr/lib/llvm-18/bin/$t"
  [ -x "$src" ] && ln -sf "$src" "/usr/local/bin/aarch64-linux-gnu-$t"
done
# linux/pgtable.h 在 5.8 才引入，5.4 要退回 asm/pgtable.h
for f in $(grep -rl "linux/pgtable.h" KernelSU/kernel 2>/dev/null); do
  if ! grep -q "KERNEL_VERSION(5, 8, 0)" "$f"; then
    sed -i 's|#include <linux/pgtable.h>|#include <linux/version.h>\n#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 8, 0)\n#include <linux/pgtable.h>\n#else\n#include <asm/pgtable.h>\n#endif|' "$f"
    echo "patched: $f"
  fi
done

# security_inode_init_security_anon 在 5.10 才加入，5.4 上跳过 LSM 标注
if grep -q "security_inode_init_security_anon" KernelSU/kernel/infra/file_wrapper.c && \
   ! grep -q "KERNEL_VERSION(5, 10, 0)" KernelSU/kernel/infra/file_wrapper.c; then
python3 - <<'PYE'
import io
p="KernelSU/kernel/infra/file_wrapper.c"
s=io.open(p).read()
old="""    error = security_inode_init_security_anon(inode, &qname, context_inode);
    if (error) {
        iput(inode);
        return ERR_PTR(error);
    }"""
new="""#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)
    error = security_inode_init_security_anon(inode, &qname, context_inode);
    if (error) {
        iput(inode);
        return ERR_PTR(error);
    }
#else
    error = 0;
#endif"""
assert old in s, "pattern not found"
io.open(p, "w").write(s.replace(old, new, 1))
PYE
echo "patched: file_wrapper.c"
fi

# 5.4 没有 __p4d_to_phys，禁用 P4D 大页分支
PM=KernelSU/kernel/hook/arm64/patch_memory.c
if [ -f "$PM" ] && ! grep -q "defined(p4d_leaf) && LINUX_VERSION_CODE" "$PM"; then
  grep -q "linux/version.h" "$PM" || sed -i 's|#include "../patch_memory.h"|#include <linux/version.h>\n#include "../patch_memory.h"|' "$PM"
  sed -i 's/#if defined(p4d_leaf)/#if defined(p4d_leaf) \&\& LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)/' "$PM"
  echo "patched: patch_memory.c"
fi

# 5.4 没有 seccomp filter cache（5.9+），这两个函数降级为 no-op
SC=KernelSU/kernel/infra/seccomp_cache.c
if [ -f "$SC" ] && ! grep -q "KERNEL_VERSION(5, 9, 0)" "$SC"; then
  sed -i 's|#include "infra/seccomp_cache.h"|#include "infra/seccomp_cache.h"\n\n#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 9, 0)\nstruct seccomp_filter;\nvoid ksu_seccomp_clear_cache(struct seccomp_filter *filter, int nr) { (void)filter; (void)nr; }\nvoid ksu_seccomp_allow_cache(struct seccomp_filter *filter, int nr) { (void)filter; (void)nr; }\n#else|' "$SC"
  printf '\n#endif /* LINUX_VERSION_CODE < 5.9.0 */\n' >> "$SC"
  echo "patched: seccomp_cache.c"
fi

# 5.4 的 fsnotify 是 handle_event 接口，pkg_observer 用了 6.x 的 handle_inode_event，先降级为 no-op
PO=KernelSU/kernel/manager/pkg_observer.c
if [ -f "$PO" ] && ! grep -q "KERNEL_VERSION(5, 9, 0)" "$PO"; then
  sed -i '1i #include <linux/version.h>\n#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 9, 0)\n#include "manager/manager_observer.h"\nint ksu_observer_init(void) { return 0; }\nvoid ksu_observer_exit(void) { }\n#else' "$PO"
  printf '\n#endif\n' >> "$PO"
  echo "patched: pkg_observer.c"
fi

# 5.4 的 task_work_add 用 bool，没有 TWA_RESUME；put_task_struct 需要 sched/task.h
AL=KernelSU/kernel/policy/allowlist.c
if [ -f "$AL" ] && ! grep -q "KSU_TWA_COMPAT" "$AL"; then
  sed -i '1i #include <linux/version.h>\n#include <linux/sched/task.h>\n#define KSU_TWA_COMPAT 1\n#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 9, 0)\n#define TWA_RESUME true\n#endif' "$AL"
  echo "patched: allowlist.c"
fi

# clocksource->vdso_clock_mode 在 5.5 才加入
CS=KernelSU/kernel/extension/cpu_spoof.c
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
  echo "patched: cpu_spoof.c"
fi

# dispatch.c 缺 init_task/tasklist_lock 等头
DP=KernelSU/kernel/supercall/dispatch.c
if [ -f "$DP" ] && ! grep -q "KSU_DISPATCH_COMPAT" "$DP"; then
  sed -i '1i #include <linux/sched/signal.h>\n#include <linux/sched/task.h>\n#include <linux/init_task.h>\n#define KSU_DISPATCH_COMPAT 1' "$DP"
  echo "patched: dispatch.c"
fi

# SELinux 子系统：5.4 没有 struct selinux_policy，改成原地改写 live policydb
cp "/mnt/e/workbuddy数据文件夹/K40pro适配root/scripts/patch-sukisu-5.4.py" /root/patch-sukisu-5.4.py
python3 /root/patch-sukisu-5.4.py

step "5/7 调整 defconfig"
DEF=arch/arm64/configs/agni_haydn_defconfig
sed -i '/^#\? *CONFIG_KSU=/d; /^#\? *CONFIG_KSU_DEBUG=/d; /^#\? *CONFIG_WERROR=/d' "$DEF"
{
  echo
  echo "CONFIG_KSU=y"
  echo "# CONFIG_KSU_DEBUG is not set"
  echo "# CONFIG_WERROR is not set"
  echo "# CONFIG_BPF_PRELOAD is not set"
  # 5.4 + clang-18/LTO/lld：genksyms 生成的 __crc_* 解析不了，链接报
  # "relocation R_AARCH64_ABS32 cannot be used against symbol '__crc_...'"
  # 本机型所有驱动都编进内核、不加载外部模块，关掉 MODVERSIONS 无副作用
  echo "# CONFIG_MODVERSIONS is not set"
} >> "$DEF"
sed -i '/^CONFIG_ASM_MODVERSIONS=/d; /^CONFIG_MODVERSIONS=/d' "$DEF"
tail -8 "$DEF"

step "6/7 编译"
export PATH=/usr/lib/llvm-18/bin:$PATH
MAKE_ARGS=(ARCH=arm64 O=out
  CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm
  OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip READELF=llvm-readelf
  CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-linux-gnu- \
  CROSS_COMPILE_COMPAT=arm-linux-gnueabi-)
make "${MAKE_ARGS[@]}" agni_haydn_defconfig
grep -E '^CONFIG_(KSU|KPROBES|EXT4_FS|WLAN|CNSS2|QCA_CLD_WLAN)=' out/.config || true
make "${MAKE_ARGS[@]}" -j6

step "7/7 校验产物"
ls -lh out/arch/arm64/boot/Image
file out/arch/arm64/boot/Image || true
strings out/arch/arm64/boot/Image | grep -m1 "Linux version" || true
cp out/arch/arm64/boot/Image /root/haydn/Image
cp out/.config /root/haydn/kernel.config
echo "===== $(date) 完成: /root/haydn/Image ====="
