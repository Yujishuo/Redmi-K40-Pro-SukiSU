#!/usr/bin/env bash
# 刷 boot 镜像（防坑版）：
#   1. 确保当前槽是 a（内核 panic 会被 bootloader 自动切到 b，导致"刷了没用"）
#   2. 刷入用 fastboot flash，刷完再确认一次 current-slot
# 用法: bash scripts/flash-boot-safe.sh <boot.img>
set -uo pipefail

IMG="${1:?用法: bash scripts/flash-boot-safe.sh <boot.img>}"
[ -f "$IMG" ] || { echo "找不到 $IMG"; exit 1; }

echo "=== 当前状态 ==="
adb devices 2>/dev/null
fastboot devices 2>/dev/null

echo "=== 进入 bootloader ==="
adb reboot bootloader 2>/dev/null
sleep 8
fastboot devices || { echo "没有 fastboot 设备：请长按电源10秒关机，再按住 音量下+电源 进入 FASTBOOT"; exit 1; }

SLOT=$(fastboot getvar current-slot 2>&1 | awk -F': ' '/current-slot/{print $2}' | tr -d '\r')
echo "当前槽: $SLOT"
if [ "$SLOT" != "a" ]; then
  echo "!! 当前槽不是 a —— 说明上次内核 panic 过，bootloader 自动切槽了。"
  echo "   切回 a 槽（否则刷到 boot_a 也不会被使用）"
  fastboot --set-active=a || exit 1
  sleep 1
fi

echo "=== 刷入 boot_a: $IMG ==="
fastboot flash boot_a "$IMG" || exit 1

SLOT2=$(fastboot getvar current-slot 2>&1 | awk -F': ' '/current-slot/{print $2}' | tr -d '\r')
echo "刷完当前槽: $SLOT2"

fastboot reboot
echo "已重启。等 40-60 秒；若卡 Logo 循环："
echo "  1) 长按电源10秒关机 → 音量下+电源 进 fastboot"
echo "  2) fastboot getvar current-slot  看是不是又变 b 了"
echo "  3) fastboot --set-active=a + fastboot flash boot_a boot_a_dump.img 救回原厂"
