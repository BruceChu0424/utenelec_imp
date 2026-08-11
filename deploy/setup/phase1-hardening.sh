#!/usr/bin/env bash
# Uten IMP 服务器 Phase 1：系统加固
# 用法（服务器上）: sudo bash phase1-hardening.sh
set -euo pipefail

echo '==> 时区与 NTP'
timedatectl set-timezone Asia/Shanghai
timedatectl set-ntp true

echo '==> 系统安全更新（unattended-upgrades）'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq unattended-upgrades apt-listchanges >/dev/null
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
cat > /etc/apt/apt.conf.d/51uten-unattended <<'EOF'
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
systemctl enable --now unattended-upgrades

echo '==> fail2ban（仅 SSH 防爆破；ufw 已限定内网，双保险）'
apt-get install -y -qq fail2ban >/dev/null
cat > /etc/fail2ban/jail.d/uten-sshd.conf <<'EOF'
[sshd]
enabled = true
port = 22
maxretry = 5
findtime = 10m
bantime = 1h
backend = systemd
EOF
systemctl enable --now fail2ban

echo '==> SSH 加固（保持密码+密钥双方式，禁用 root 直连）'
install -d -m 0755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/60-uten-imp.conf <<'EOF'
PermitRootLogin no
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
EOF
sshd -t
systemctl reload ssh

echo '==> 基础工具'
apt-get install -y -qq curl jq ca-certificates gnupg >/dev/null

echo '==> 完成'
timedatectl | head -4
systemctl is-active unattended-upgrades fail2ban ssh
