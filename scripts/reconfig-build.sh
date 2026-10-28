#!/bin/bash
# 改过 defconfig 之后用这个：先重新生成 .config，再编译。
# rebuild.sh 只跑 make，不会重新应用 defconfig，配置改动不会生效。
set -e
cd /root/haydn/kernel
export PATH=/usr/lib/llvm-18/bin:/usr/bin:/bin:/usr/sbin:/sbin

ARGS=(
  ARCH=arm64 O=out
  CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm
  OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip READELF=llvm-readelf
  CLANG_TRIPLE=aarch64-linux-gnu-
  CROSS_COMPILE=aarch64-linux-gnu-
  CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
)

echo "=== 1/3 生成 .config ==="
make "${ARGS[@]}" agni_haydn_defconfig

echo "=== 2/3 关键配置核对 ==="
grep -E '^CONFIG_(KSU|KPM|KALLSYMS|KALLSYMS_ALL|MODVERSIONS|KPROBES)=' out/.config || true

echo "=== 3/3 编译 ==="
make "${ARGS[@]}" -j6

ls -lh out/arch/arm64/boot/Image
cp out/arch/arm64/boot/Image /root/haydn/Image
echo "===== done: $(date) ====="
