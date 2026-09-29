#!/bin/bash
# 「已有服务器应用可配置计划」一节的机械步骤（deploy/simple/RUNBOOK.zh-CN.md）。
# 用法：sudo bash install-update-schedule.sh <已核对的暂存目录>
# 暂存目录里应有 update_schedule.py、uten-imp-updater.service、uten-imp-updater.timer、
# uten-imp-updater.sh 四个文件（与仓库 deploy/simple/ 一致，sha256 先行核对）。
# 仅做安装与启用；数据库前向迁移必须已经完成（脚本不碰数据库）。
set -euo pipefail

SRC="${1:?用法: sudo bash install-update-schedule.sh <暂存目录>}"
[ "$(id -u)" -eq 0 ] || { echo "必须以 root 运行"; exit 1; }

for f in update_schedule.py uten-imp-updater.service \
  uten-imp-updater.timer uten-imp-updater.sh; do
  [ -f "$SRC/$f" ] || { echo "缺少 $SRC/$f"; exit 1; }
done

# 旧单元先备份（若备份目录尚无副本），避免覆盖后无法回退。
backup_dir=/var/backups/uten-imp-schedule-units-$(date +%Y%m%d%H%M%S)
install -d -o root -g root -m 0700 "$backup_dir"
for u in /etc/systemd/system/uten-imp-updater.service \
  /etc/systemd/system/uten-imp-updater.timer; do
  [ -f "$u" ] && cp -a "$u" "$backup_dir/" || true
done

systemctl stop uten-imp-updater.timer 2>/dev/null || true

install -d -o root -g root -m 0755 /usr/local/lib/uten-imp
install -o root -g root -m 0644 "$SRC/update_schedule.py" \
  /usr/local/lib/uten-imp/update_schedule.py
install -o root -g root -m 0644 "$SRC/uten-imp-updater.service" \
  "$SRC/uten-imp-updater.timer" /etc/systemd/system/
install -o root -g root -m 0755 "$SRC/uten-imp-updater.sh" \
  /usr/local/sbin/uten-imp-updater

systemctl daemon-reload
systemctl enable --now uten-imp-updater.timer

echo "=== 已安装文件摘要（应与仓库 deploy/simple/ 一致）==="
sha256sum /usr/local/lib/uten-imp/update_schedule.py /usr/local/sbin/uten-imp-updater
echo "=== 单元 ==="
systemctl cat uten-imp-updater.service uten-imp-updater.timer | grep -E '^(ExecStart|OnCalendar|Description|#)' | head -10
echo "=== 定时器 ==="
systemctl list-timers --all uten-imp-updater.timer --no-pager | head -4
echo "=== 旧单元备份 ==="
ls -1 "$backup_dir"
