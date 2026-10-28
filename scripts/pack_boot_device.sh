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
