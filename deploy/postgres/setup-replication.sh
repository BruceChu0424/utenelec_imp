#!/usr/bin/env bash
# =====================================================================
# 一键搭建 PostgreSQL 主（公司本地）→ 云端副本（hot standby，只读）流复制 + 物理复制槽。
#
# 设计：本地永远是唯一可写主库；云端副本只读。断网期间主库靠 wal_keep_size 保留 WAL，
#       恢复后副本经复制槽「cloud_rep」从断点续传，不丢数据、无需自写同步逻辑。
#
# 用法（在【云端副本服务器】上跑，需已通过 VPN/专线连到主库）：
#   PRIMARY_HOST=10.8.0.1 REPL_PASSWORD='强随机密码' ./setup-replication.sh
# =====================================================================
set -euo pipefail

PRIMARY_HOST="${PRIMARY_HOST:?需设 PRIMARY_HOST=主库 VPN 内网 IP}"
PRIMARY_PORT="${PRIMARY_PORT:-5432}"
REPL_USER="${REPL_USER:-repl}"
REPL_PASSWORD="${REPL_PASSWORD:?需设 REPL_PASSWORD=复制用户密码}"
SLOT="${SLOT:-cloud_rep}"
REPLICA_DATA="${REPLICA_DATA:-/var/lib/postgresql/data}"

echo "==> 1/3 主库建复制用户 + 物理复制槽（已存在则忽略）"
# 角色已存在会报错，忽略；务必提前在主库 pg_hba.conf 放行复制网段（见 pg_hba-replication.conf.example）。
PGPASSWORD="${PGPASSWORD:-}" psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U postgres -v ON_ERROR_STOP=0 -c \
  "CREATE ROLE $REPL_USER WITH REPLICATION LOGIN PASSWORD '$REPL_PASSWORD';" \
  2>/dev/null || echo "    角色 $REPL_USER 可能已存在（忽略）"
PGPASSWORD="${PGPASSWORD:-}" psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U postgres -v ON_ERROR_STOP=0 -c \
  "SELECT pg_create_physical_replication_slot('$SLOT');" \
  2>/dev/null || echo "    复制槽 $SLOT 可能已存在（忽略）"

echo "==> 2/3 副本停库 → pg_basebackup 从主库克隆（-R 自动写 standby.signal/primary_conninfo/槽名）"
if command -v pg_ctlcluster >/dev/null 2>&1; then
  pg_ctlcluster 16 main stop 2>/dev/null || true
elif command -v systemctl >/dev/null 2>&1; then
  systemctl stop postgresql 2>/dev/null || true
fi
rm -rf "${REPLICA_DATA:?}"/*

export PGPASSWORD="$REPL_PASSWORD"
pg_basebackup -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$REPL_USER" \
  -D "$REPLICA_DATA" -Fp -Xs -P -R -S "$SLOT"

# 确认副本用槽（-R 通常已写；双保险）。
echo "primary_slot_name = '$SLOT'" >> "$REPLICA_DATA/postgresql.auto.conf"

if command -v pg_ctlcluster >/dev/null 2>&1; then
  pg_ctlcluster 16 main start
elif command -v systemctl >/dev/null 2>&1; then
  systemctl start postgresql
fi

echo "==> 3/3 验证：主库复制状态（state 应为 streaming）"
PGPASSWORD="${PGPASSWORD:-}" psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U postgres -c \
  "SELECT application_name, state, sync_state, sent_lsn, replay_lsn FROM pg_stat_replication;"

echo "完成。复制槽 $SLOT 启用：主库健康时云端 App 全走主库；断网时只读走副本、写 503；恢复后自动续传。"
