#!/bin/bash
# 增量重编译内核（只改了 SukiSU 部分时用）
set -e
cd /root/haydn/kernel
export PATH=/usr/lib/llvm-18/bin:/usr/bin:/bin:/usr/sbin:/sbin
make ARCH=arm64 O=out \
  CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm \
  OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip READELF=llvm-readelf \
  CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-linux-gnu- \
  CROSS_COMPILE_COMPAT=arm-linux-gnueabi- -j6 2>&1 | tail -40
ls -lh out/arch/arm64/boot/Image
cp out/arch/arm64/boot/Image /root/haydn/Image
echo "===== rebuild done: $(date) ====="
