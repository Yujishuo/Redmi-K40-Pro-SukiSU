#!/bin/bash
# 全量干净重编译（排除增量编译导致的镜像损坏）
set -e
cd /root/haydn/kernel
export PATH=/usr/lib/llvm-18/bin:/usr/bin:/bin:/usr/sbin:/sbin

# 确保 5.4 补丁已应用（boot_event 的改动先不加，隔离风险）
cp "/mnt/e/workbuddy数据文件夹/K40pro适配root/scripts/patch-sukisu-5.4.py" /root/patch-sukisu-5.4.py
KSU_PATCH_BOOT_EVENT="${KSU_PATCH_BOOT_EVENT:-0}" python3 /root/patch-sukisu-5.4.py

echo "===== 清理 out/ ====="
rm -rf out
mkdir -p out

MAKE_ARGS=(ARCH=arm64 O=out
  CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm
  OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip READELF=llvm-readelf
  CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-linux-gnu-
  CROSS_COMPILE_COMPAT=arm-linux-gnueabi-)

make "${MAKE_ARGS[@]}" agni_haydn_defconfig
grep -E '^CONFIG_(KSU|KPROBES|MODVERSIONS)=' out/.config || true
make "${MAKE_ARGS[@]}" -j6 2>&1 | tail -25

ls -l out/arch/arm64/boot/Image
cp out/arch/arm64/boot/Image /root/haydn/Image
echo "===== clean build done: $(date) size=$(stat -c %s /root/haydn/Image) ====="
