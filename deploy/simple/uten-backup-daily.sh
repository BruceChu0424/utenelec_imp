#!/bin/bash
# Uten IMP 每日数据备份（ADR-060 简化链配套）
# - PostgreSQL 自定义格式全量 dump → /data/uten-imp-backups/pg/（RAID1，与系统盘分离）
# - 附件目录（本地存储启用时）rsync 快照 → /data/uten-imp-backups/attachments/
# - 保留策略：只保留最新 1 份（新备份成功后删除旧的）
# - 附带 RAID/磁盘健康巡检，异常写入日志并输出非零关键行（不中断备份）
set -euo pipefail

BACKUP_ROOT=/data/uten-imp-backups
PG_DIR="$BACKUP_ROOT/pg"
ATT_SRC=/data/uten-imp/attachments
ATT_DIR="$BACKUP_ROOT/attachments"
KEEP=1
LOG_TAG=uten-backup

mkdir -p "$PG_DIR" "$ATT_DIR"
# pg_dump 以 postgres 身份执行，pg 目录需归其所有
chown postgres:postgres "$PG_DIR"

stamp=$(date +%Y%m%d-%H%M%S)
dump="$PG_DIR/uten_imp-$stamp.dump"

# 1) 数据库全量（自定义格式，可 pg_restore 选择性恢复）
if sudo -u postgres pg_dump -Fc -d uten_imp -f "$dump"; then
  echo "[$LOG_TAG] OK dump=$dump size=$(du -h "$dump" | cut -f1)"
else
  echo "[$LOG_TAG] FATAL pg_dump failed" >&2
  exit 1
fi

# 2) 附件（当前上传默认关闭，量小；启用后同样适用）
if [ -d "$ATT_SRC" ]; then
  rsync -a --delete "$ATT_SRC/" "$ATT_DIR/" 2>/dev/null \
    && echo "[$LOG_TAG] OK attachments synced" \
    || echo "[$LOG_TAG] WARN attachments rsync failed"
fi

# 3) 轮转：只留最新 KEEP 份（先确保本轮 dump 成功，再删旧）
ls -1t "$PG_DIR"/uten_imp-*.dump 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f

# 4) 健康/水位巡检（只告警不失败）
raid=$(cat /proc/mdstat | grep -A1 md0 | grep -oE "\[U+\]" | head -1)
[ "$raid" = "[UU]" ] || echo "[$LOG_TAG] WARN RAID1 非双UP: $raid"
usage=$(df --output=pcent /data | tail -1 | tr -dc '0-9')
[ "$usage" -lt 85 ] || echo "[$LOG_TAG] WARN /data 使用率 ${usage}%"

exit 0
