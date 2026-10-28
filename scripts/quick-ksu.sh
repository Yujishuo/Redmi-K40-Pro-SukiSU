#!/usr/bin/env bash
# 只编译 drivers/kernelsu，用于快速迭代 5.4 兼容补丁
set -uo pipefail

SRC_WIN="/mnt/e/workbuddy数据文件夹/K40pro适配root/scripts"
cp "$SRC_WIN/patch-sukisu-5.4.py" /root/patch-sukisu-5.4.py || exit 1

cd /root/haydn/kernel || exit 1
python3 /root/patch-sukisu-5.4.py || exit 1

export PATH=/usr/lib/llvm-18/bin:$PATH
make ARCH=arm64 O=out CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm \
  OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip READELF=llvm-readelf \
  CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-linux-gnu- \
  CROSS_COMPILE_COMPAT=arm-linux-gnueabi- -j6 drivers/kernelsu/ 2>&1 | tail -60
