#!/usr/bin/env bash
# 刷入新的 boot 镜像（默认 slot a）
# 用法: bash scripts/flash-boot.sh new-boot.img [a|b]
set -euo pipefail

IMG="${1:?用法: bash scripts/flash-boot.sh <boot.img> [a|b]}"
SLOT="${2:-a}"
[ -f "$IMG" ] || { echo "找不到 $IMG"; exit 1; }

echo "即将刷入 boot_${SLOT}：$IMG"
read -r -p "确认继续？(输入 yes) " ans
[ "$ans" = "yes" ] || { echo "已取消"; exit 1; }

adb reboot bootloader
sleep 6
fastboot getvar current-slot || true
fastboot flash "boot_${SLOT}" "$IMG"
fastboot reboot
echo "已重启。首次开机可能 2-5 分钟；若卡 LOGO/循环重启，执行 bash scripts/restore-boot.sh"
