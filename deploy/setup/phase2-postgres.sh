#!/usr/bin/env bash
# Uten IMP 服务器 Phase 2：PostgreSQL 16（数据目录 /data）+ 角色/密码 + pgBackRest
# 用法: sudo bash phase2-postgres.sh
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

PGDATA=/data/postgresql/16/main
SECRETS=/etc/uten-imp/postgres-secrets

echo '==> 安装 PostgreSQL 16 + pgBackRest'
apt-get update -qq
apt-get install -y -qq postgresql-16 pgbackrest >/dev/null

echo '==> 重建集群到 /data（带数据校验和）'
systemctl stop postgresql
if pg_lsclusters | grep -qE '^16 +main'; then
  pg_dropcluster 16 main --stop 2>/dev/null || pg_dropcluster 16 main
fi
install -d -m 0700 -o postgres -g postgres /data/postgresql
pg_createcluster 16 main -d "$PGDATA" -- --data-checksums --auth-local=peer --auth-host=scram-sha-256
install -d -m 0750 -o postgres -g postgres /data/backups/pgbackrest

echo '==> 参数配置（16GB 内存 / 复制与 WAL 保留按项目基线）'
cat > /etc/postgresql/16/main/conf.d/90-uten-imp.conf <<'EOF'
listen_addresses = 'localhost'
port = 5432
ssl = on
shared_buffers = 4GB
effective_cache_size = 12GB
work_mem = 32MB
maintenance_work_mem = 512MB
max_connections = 200
wal_level = replica
wal_keep_size = 2GB
max_slot_wal_keep_size = 16GB
synchronous_standby_names = ''
archive_mode = on
archive_command = 'pgbackrest --stanza=uten-imp archive-push %p'
archive_timeout = 300
log_min_duration_statement = 1000
log_checkpoints = on
log_connections = on
log_disconnections = on
log_lock_waits = on
password_encryption = scram-sha-256
EOF
systemctl start postgresql

echo '==> 生成三个独立 20 位随机密码（0600，仅 postgres 可读）'
install -d -m 0700 -o postgres -g postgres "$SECRETS"
for role in admin repl app; do
  if [ ! -s "$SECRETS/$role.password" ]; then
    openssl rand -base64 27 | tr -d '/+=' | head -c 20 > "$SECRETS/$role.password"
  fi
  chown postgres:postgres "$SECRETS/$role.password"
  chmod 0600 "$SECRETS/$role.password"
done

echo '==> 创建角色与数据库'
sudo -u postgres psql -v ON_ERROR_STOP=1 <<EOF
ALTER ROLE postgres PASSWORD '$(cat $SECRETS/admin.password)';
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'uten_repl') THEN
    CREATE ROLE uten_repl LOGIN REPLICATION PASSWORD '$(cat $SECRETS/repl.password)';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'uten') THEN
    CREATE ROLE uten LOGIN PASSWORD '$(cat $SECRETS/app.password)';
  END IF;
END
\$\$;
SELECT 'roles ok';
EOF
sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='uten_imp'" | grep -q 1 \
  || sudo -u postgres createdb -O uten uten_imp

echo '==> 配置 pgBackRest（每日全量，硬链接去重，保留 7 份）'
cat > /etc/pgbackrest.conf <<'EOF'
[global]
repo1-path=/data/backups/pgbackrest
repo1-retention-full=7
repo1-hardlink=y
repo1-bundle=y
process-max=4
log-level-console=info
log-level-file=detail
start-fast=y
stop-auto=y

[uten-imp]
pg1-path=/data/postgresql/16/main
pg1-port=5432
EOF
chmod 0640 /etc/pgbackrest.conf
chown root:postgres /etc/pgbackrest.conf

echo '==> 初始化 stanza 并做首次全量备份'
sudo -u postgres pgbackrest --stanza=uten-imp stanza-create
sudo -u postgres pgbackrest --stanza=uten-imp --type=full backup

echo '==> 每日备份 systemd timer（凌晨 02:17，错峰）'
cat > /etc/systemd/system/uten-pgbackup.service <<'EOF'
[Unit]
Description=Uten IMP PostgreSQL daily pgBackRest backup
After=postgresql.service

[Service]
Type=oneshot
User=postgres
ExecStart=/usr/bin/pgbackrest --stanza=uten-imp --type=full backup
ExecStartPost=/usr/bin/pgbackrest --stanza=uten-imp expire
EOF
cat > /etc/systemd/system/uten-pgbackup.timer <<'EOF'
[Unit]
Description=Uten IMP PostgreSQL daily backup timer

[Timer]
OnCalendar=*-*-* 02:17:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now uten-pgbackup.timer

echo '==> 验证'
sudo -u postgres psql -tAc "SELECT version(); SELECT pg_is_in_recovery(); SHOW data_directory; SHOW ssl;"
sudo -u postgres pgbackrest --stanza=uten-imp info
systemctl list-timers uten-pgbackup.timer --no-pager
ls -l "$SECRETS"
