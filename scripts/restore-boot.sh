#!/usr/bin/env bash
# 一键回滚：把备份的 boot_a 原始镜像刷回去
# 用法: bash scripts/restore-boot.sh [a|b]
set -euo pipefail

SLOT="${1:-a}"
BACKUP="boot_a_dump.img"

[ -f "$BACKUP" ] || { echo "找不到备份 $BACKUP"; exit 1; }

echo "即将用 $BACKUP 覆盖 boot_${SLOT}（这是当前可正常开机的 VK 内核）"
read -r -p "确认继续？(输入 yes) " ans
[ "$ans" = "yes" ] || { echo "已取消"; exit 1; }

adb reboot bootloader
sleep 6
fastboot flash "boot_${SLOT}" "$BACKUP"
fastboot reboot
echo "回滚完成。"
