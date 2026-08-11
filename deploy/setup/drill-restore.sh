#!/usr/bin/env bash
set -euo pipefail
echo '==> 从最新备份恢复到隔离目录'
rm -rf /tmp/pg-restore-drill /tmp/pg-restore-drill.log
install -d -m 0700 -o postgres -g postgres /tmp/pg-restore-drill
sudo -u postgres pgbackrest --stanza=uten-imp --pg1-path=/tmp/pg-restore-drill restore --log-level-console=warn
echo '==> 为临时实例补一份最小配置（与生产配置完全隔离）'
sudo -u postgres tee /tmp/pg-restore-drill/postgresql.conf >/dev/null <<'CONF'
port = 5433
listen_addresses = ''
unix_socket_directories = '/var/run/postgresql'
ssl = off
shared_buffers = 128MB
max_connections = 200
CONF
sudo -u postgres cp /etc/postgresql/16/main/pg_hba.conf /tmp/pg-restore-drill/pg_hba.conf
sudo -u postgres cp /etc/postgresql/16/main/pg_ident.conf /tmp/pg-restore-drill/pg_ident.conf
echo '==> 用恢复出的数据在 5433 端口启动临时实例'
sudo -u postgres /usr/lib/postgresql/16/bin/pg_ctl -D /tmp/pg-restore-drill -o "-p 5433 -c listen_addresses=''" -w -t 60 start -l /tmp/pg-restore-drill.log
echo '==> 验证恢复数据可读'
sudo -u postgres psql -h /var/run/postgresql -p 5433 -d postgres -tAc "SELECT datname FROM pg_database WHERE datname='uten_imp';"
sudo -u postgres psql -h /var/run/postgresql -p 5433 -d uten_imp -tAc "SELECT 'restore readable OK';"
echo '==> 关闭并清理'
sudo -u postgres /usr/lib/postgresql/16/bin/pg_ctl -D /tmp/pg-restore-drill -w stop -m fast
rm -rf /tmp/pg-restore-drill /tmp/pg-restore-drill.log
echo 'RESTORE_DRILL_OK'
