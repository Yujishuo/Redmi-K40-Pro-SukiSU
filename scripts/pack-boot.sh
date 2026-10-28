#!/usr/bin/env bash
# 用编译出来的 Image 重打包当前 boot_a，保留原 ramdisk / cmdline / header
# 用法: bash scripts/pack-boot.sh Image
set -euo pipefail

IMG="${1:?用法: bash scripts/pack-boot.sh <Image 文件>}"
[ -f "$IMG" ] || { echo "找不到 $IMG"; exit 1; }

DEV=/data/local/tmp

echo "[1/5] 推送内核到设备..."
adb push "$IMG" "$DEV/sukisu_Image" >/dev/null

echo "[2/5] 生成设备端打包脚本..."
cat > ./pack_boot_device.sh <<'EOS'
#!/system/bin/sh
set -e
KB=/data/adb/ksu/bin/magiskboot
DEV=/data/local/tmp
cd "$DEV"
rm -rf boot_work
mkdir boot_work
cd boot_work
$KB unpack -h /dev/block/by-name/boot_a
echo "--- 原 boot header ---"
head -8 header 2>/dev/null || true
cp ../sukisu_Image kernel
$KB repack /dev/block/by-name/boot_a new-boot.img
ls -l new-boot.img
EOS

adb push ./pack_boot_device.sh "$DEV/pack_boot_device.sh" >/dev/null

echo "[3/5] 设备端解包 + 替换 kernel + 重打包..."
adb shell "su -c 'sh $DEV/pack_boot_device.sh'"

echo "[4/5] 拉回本地..."
adb pull "$DEV/boot_work/new-boot.img" ./new-boot.img >/dev/null
ls -lh ./new-boot.img
rm -f ./pack_boot_device.sh

echo "[5/5] 完成。确认无误后执行： bash scripts/flash-boot.sh new-boot.img"
