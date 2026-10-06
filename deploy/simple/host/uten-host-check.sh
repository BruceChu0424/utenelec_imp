#!/bin/bash
# 每 10 分钟的只读巡检 (ADR-157)。安装为 /usr/local/sbin/uten-host-check (root:root 0755),
# 由 uten-host-check.timer 触发; 发现问题调用 uten-alert, 不修改任何东西。
set -uo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
alert=/usr/local/sbin/uten-alert

# 1. 磁盘: 已用 >= 90%、剩余 < 20GiB 或 inode >= 90% 报"不足"; >= 80% 报"超过八成"
for item in "/:系统盘" "/data:数据盘" "/var/lib/uten-imp-media:附件盘" "/srv/uten-backup:本机备份盘"; do
  mount_point=${item%%:*}
  name=${item#*:}
  if ! mountpoint -q "$mount_point"; then
    "$alert" "disk-$mount_point" "$name 没有挂载"
    continue
  fi
  read -r used avail inodes < <(df -B1 --output=pcent,avail,ipcent "$mount_point" \
    | awk 'NR==2 { gsub("%", ""); print $1, $2, $3 }')
  if [ "${used:-100}" -ge 90 ] || [ "${avail:-0}" -lt 21474836480 ] || [ "${inodes:-100}" -ge 90 ]; then
    "$alert" "disk-$mount_point" "$name 已用 ${used:-?}%"
  elif [ "${used:-100}" -ge 80 ]; then
    "$alert" "diskwarn-$mount_point" "$name 已用 ${used}%"
  fi
done

# 2. RAID1 必须是双盘 [UU]
grep -A1 '^md0' /proc/mdstat | grep -q '\[UU\]' || "$alert" raid-md0 "数据盘阵列不是双盘正常状态"

# 3. 关键服务在运行
for item in "uten-imp:ERP 后台" "postgresql@16-main:数据库" "nginx:网页入口" \
            "clamav-daemon:病毒扫描" "uten-paddle-ocr:发票识别"; do
  systemctl is-active --quiet "${item%%:*}" || "$alert" "down-${item%%:*}" "${item#*:}"
done

# 4. WAL 归档: 最近一次失败晚于最近一次成功就报
archive_failing=$(runuser -u postgres -- psql -XAt -d postgres -c \
  "select coalesce(last_failed_time > coalesce(last_archived_time, 'epoch'), false) from pg_stat_archiver" 2>/dev/null)
[ "$archive_failing" = "f" ] || "$alert" wal-archive

# 5. pgBackRest: repo1 与 repo2 都要有 26 小时内完成的备份
read -r repos oldest < <(runuser -u postgres -- pgbackrest --stanza=uten-imp --output=json --log-level-file=off info 2>/dev/null \
  | jq -r '.[0].backup | group_by(.database["repo-key"]) | "\(length) \(map(max_by(.timestamp.stop).timestamp.stop) | min)"' 2>/dev/null)
if ! { [ "${repos:-0}" -ge 2 ] && [ $(( $(date +%s) - ${oldest:-0} )) -le 93600 ]; }; then
  "$alert" backup-stale "数据库备份超过 26 小时"
fi

# 6. 配套备份每天两次 (03:40/13:10): 最长间隔约 15 小时, 超过 16 小时没有新的成功就报
paired=$(stat -c %Y /data/uten-imp-backups/paired/latest-success.json 2>/dev/null || echo 0)
[ $(( $(date +%s) - paired )) -le 57600 ] || "$alert" backup-stale-paired "配套备份超过 16 小时"
exit 0
