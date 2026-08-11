#!/usr/bin/env bash
# Uten IMP 服务器 Phase 3：Java 21 + Nginx + 服务账号 + 目录 + 生产环境文件 + systemd 单元
# 用法: sudo bash phase3-runtime.sh
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo '==> 安装 Java 21 + Nginx'
apt-get update -qq
apt-get install -y -qq openjdk-21-jre-headless nginx >/dev/null

echo '==> 服务账号与目录'
getent group uten-imp >/dev/null || groupadd --system uten-imp
id -u uten-imp >/dev/null 2>&1 || \
  useradd --system --gid uten-imp --home-dir /nonexistent --shell /usr/sbin/nologin uten-imp
install -d -m 0755 -o root    -g root     /opt/uten-imp/releases
install -d -m 0750 -o root    -g uten-imp /etc/uten-imp
install -d -m 0750 -o uten-imp -g uten-imp /data/uten-imp/attachments

echo '==> 生成生产秘密（JWT/PGP/HMAC/引导超管，各自独立强随机）'
gen() { openssl rand -base64 48 | tr -d '/+=' | head -c "${1:-44}"; }
APP_DB_PASSWORD="$(cat /etc/uten-imp/postgres-secrets/app.password)"

if [ ! -f /etc/uten-imp/server.env ]; then
cat > /etc/uten-imp/server.env <<EOF
# Uten IMP 生产环境文件（0600，root:uten-imp）。禁止入库、禁止外传。
UTEN_PROFILE=prod
UTEN_DEPLOYMENT_SITE=local
UTEN_LOCAL_ALLOWED_CIDRS=127.0.0.0/8,::1/128,192.168.0.0/23

UTEN_DB_URL=jdbc:postgresql://127.0.0.1:5432/uten_imp
UTEN_DB_USER=uten
UTEN_DB_PASSWORD=${APP_DB_PASSWORD}
UTEN_DB_POOL_MAX=20
UTEN_DB_POOL_MIN_IDLE=2
UTEN_DB_CONNECTION_TIMEOUT_MS=10000
UTEN_DB_IDLE_TIMEOUT_MS=600000
UTEN_DB_MAX_LIFETIME_MS=1800000
UTEN_FLYWAY_BASELINE_ON_MIGRATE=false

UTEN_MAX_JSON_BODY_BYTES=1048576
UTEN_FINANCE_ASSET_POSTED_WORKFLOWS_ENABLED=false

UTEN_AUDIT_RETENTION_ENABLED=true
UTEN_AUDIT_RETENTION_CRON=0 17 3 * * *
UTEN_SCHEDULING_POOL_SIZE=4

UTEN_JWT_SECRET=$(gen 48)
UTEN_JWT_ISSUER=uten-imp-production
UTEN_PGP_MASTER_KEY=$(gen 48)
UTEN_PGP_KEY_VERSION=1
UTEN_HMAC_KEY=$(gen 48)

UTEN_CORS_ORIGINS=http://192.168.1.13,http://utenelec-imp-server
UTEN_REQUIRE_HTTPS=false
UTEN_SSL_ENABLED=false
UTEN_TRUSTED_PROXY_REGEX=127\\..*|::1

BOOTSTRAP_ADMIN_PASSWORD=$(gen 20)

UTEN_SMS_PROVIDER=log

UTEN_STORAGE_PROVIDER=local
UTEN_STORAGE_MAX_BYTES=26214400
UTEN_STORAGE_PRESIGN_EXPIRY=300
UTEN_STORAGE_LOCAL_DIR=/data/uten-imp/attachments
UTEN_OSS_REQUIRE_VERSIONING=false

UTEN_POLICY_INTELLIGENCE_ENABLED=false
EOF
fi
chown root:uten-imp /etc/uten-imp/server.env
chmod 0640 /etc/uten-imp/server.env

echo '==> 安装 systemd 单元（后端 + 双 watchdog + nginx 自动拉起）'
cd /tmp/uten-deploy
install -m 0644 systemd/uten-imp.service.example                 /etc/systemd/system/uten-imp.service
install -d -m 0755 /etc/systemd/system/nginx.service.d
install -m 0644 systemd/nginx-uten-imp-override.conf.example     /etc/systemd/system/nginx.service.d/uten-imp.conf
install -m 0644 systemd/uten-imp-watchdog.service.example        /etc/systemd/system/uten-imp-watchdog.service
install -m 0644 systemd/uten-imp-watchdog.timer.example          /etc/systemd/system/uten-imp-watchdog.timer
install -m 0644 systemd/uten-imp-entry-watchdog.service.example  /etc/systemd/system/uten-imp-entry-watchdog.service
install -m 0644 systemd/uten-imp-entry-watchdog.timer.example    /etc/systemd/system/uten-imp-entry-watchdog.timer
systemctl daemon-reload

echo '==> Nginx 默认站点下线，等待 uten-imp 站点配置'
rm -f /etc/nginx/sites-enabled/default

echo '==> 完成'
java -version 2>&1 | head -1
nginx -v 2>&1
id uten-imp
ls -ld /opt/uten-imp/releases /data/uten-imp/attachments
ls -l /etc/uten-imp/server.env
