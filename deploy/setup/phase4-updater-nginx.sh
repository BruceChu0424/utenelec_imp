#!/usr/bin/env bash
# Uten IMP 服务器 Phase 4：安装自动更新器 + Nginx 站点配置
# 用法: sudo bash phase4-updater-nginx.sh
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo '==> 安装 python3-venv 并建更新器隔离环境'
apt-get update -qq
apt-get install -y -qq python3-venv >/dev/null
install -d -m 0755 -o root -g root /opt/uten-imp/updater
python3 -m venv /opt/uten-imp/updater/venv
/opt/uten-imp/updater/venv/bin/pip install --quiet --no-cache-dir oss2==2.19.1

echo '==> 安装更新器文件'
install -m 0755 -o root -g root /tmp/uten-deploy/updater/uten-imp-updater.sh /opt/uten-imp/updater/uten-imp-updater.sh
install -m 0755 -o root -g root /tmp/uten-deploy/updater/oss_io.py          /opt/uten-imp/updater/oss_io.py
install -m 0644 /tmp/uten-deploy/updater/uten-imp-updater.service /etc/systemd/system/uten-imp-updater.service
install -m 0644 /tmp/uten-deploy/updater/uten-imp-updater.timer   /etc/systemd/system/uten-imp-updater.timer

echo '==> 安装 Nginx 站点（内网 HTTP 过渡配置）'
install -m 0644 /tmp/uten-deploy/nginx/uten-imp-http-lan.conf /etc/nginx/conf.d/uten-imp.conf
nginx -t

echo '==> OSS 拉取凭证占位（0640，待业主提供只读 RAM AK/SK 后填入）'
if [ ! -f /etc/uten-imp/oss-pull.env ]; then
cat > /etc/uten-imp/oss-pull.env <<'EOF'
# Uten IMP 发布仓只读凭证（RAM 用户仅 GetObject/ListObjects 权限）
OSS_ACCESS_KEY_ID=__PENDING__
OSS_ACCESS_KEY_SECRET=__PENDING__
OSS_BUCKET=__PENDING__
OSS_ENDPOINT=__PENDING__
EOF
fi
chown root:uten-imp /etc/uten-imp/oss-pull.env
chmod 0640 /etc/uten-imp/oss-pull.env

systemctl daemon-reload
echo '==> 完成（uten-imp-updater.timer 暂不启用，等 OSS 凭证与首个制品就绪）'
/opt/uten-imp/updater/venv/bin/python -c "import oss2; print('oss2', oss2.__version__)"
ls -l /opt/uten-imp/updater/ /etc/uten-imp/
