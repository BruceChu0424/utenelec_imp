# 主机配置片段 (2026-10-06 服务器安全整改, ADR-157)

本目录是服务器上 systemd 单元以外的系统配置与运维脚本的唯一来源。systemd 单元在
[../units/](../units/)。执行顺序、验证与回滚见 [RUNBOOK](../RUNBOOK.zh-CN.md)「服务器安全基线」与
[治理记录](../../../docs/99-项目治理/2026-10-06-服务器安全整改.md)。

## 安装纪律

- 从 `main` 的 git blob 取原始字节 (Git Bash: `git show main:deploy/simple/host/<文件> > <本机文件>`),
  不要直接拷工作区文件 (可能是 CRLF), 也不要用 PowerShell 重定向 (会转码)。
- 传到服务器走 SSH 标准输入, 服务器上不落临时文件, 例如
  `ssh <运维账号>@<服务器IP> 'sudo install -o root -g root -m 0644 /dev/stdin /etc/sysctl.d/60-uten-net.conf' < sysctl-60-uten-net.conf`,
  装完 `sha256sum <目标>` 与本机 `sha256sum` 比对。多步命令同样写在本机文件里, 用
  `ssh ... 'sudo bash -s' < 本机脚本` 执行, 不把脚本拷上服务器。
- 秘密 (webhook 地址、备份仓口令) 不出现在任何命令行参数里: 用 `sudoedit`, 或在服务器上由管道直接生成。
- 带 `__XXX__` 或 `REPLACE` 的占位符只在服务器上替换, 真实地址和口令不提交进仓库。

## 文件清单

| 文件 | 安装到 | 属主/权限 | 何时装 |
|---|---|---|---|
| `pgbackrest-20-uten-imp-repo2.conf.example` | `/etc/pgbackrest/conf.d/20-uten-imp-repo2.conf` | root:postgres 0640 | 本机备份卷建好后 (口令在服务器上生成) |
| [../../systemd/journald-uten-imp.conf.example](../../systemd/journald-uten-imp.conf.example) | `/etc/systemd/journald.conf.d/uten-imp.conf` | root 0644 | journal 清理以后; 2G、30 天、封存 (`journalctl --setup-keys` 的验证密钥只抄进密码管理器) |
| `logrotate-uten-auth` | `/etc/logrotate.d/uten-auth` | root 0644 | 同时从 `/etc/logrotate.d/rsyslog` 删掉 auth.log 一行 |
| `sysctl-60-uten-net.conf` | `/etc/sysctl.d/60-uten-net.conf` | root 0644 | 随时, `sysctl --system` 生效 |
| `timesyncd-10-uten.conf` | `/etc/systemd/timesyncd.conf.d/10-uten.conf` | root 0644 | 随时, 重启 systemd-timesyncd |
| `apt-52uten-origins` | `/etc/apt/apt.conf.d/52uten-origins` | root 0644 | 随时 |
| `fail2ban-00-uten-ignore.local.example` | `/etc/fail2ban/jail.d/00-uten-ignore.local` | root 0644 | 改 SSH 之前 |
| `sshd-00-uten-imp.conf.example` | `/etc/ssh/sshd_config.d/00-uten-imp.conf` | root 0600 | 手工维护的主机; 先挂自动回退定时器 |
| `cloud-init-99-uten-ssh-pwauth.cfg` | `/etc/cloud/cloud.cfg.d/99-uten-ssh-pwauth.cfg` | root 0644 | 与上一行一起 |
| `nginx-service-20-uten.conf` | `/etc/systemd/system/nginx.service.d/20-uten.conf` | root 0644 | 维护窗口 (nginx 秒级重启) |
| `postgresql-20-uten-backup-order.conf` | `/etc/systemd/system/postgresql@16-main.service.d/20-uten-backup-order.conf` | root 0644 | 本机备份卷建好后; 只 daemon-reload, 下次开机生效 |
| `clamd-uten-alerts.conf.snippet` | 追加到 `/etc/clamav/clamd.conf` | - | 维护窗口 (上传约 20 秒不可用) |
| `smartd.conf.example` | 替换 `/etc/smartd.conf` 的 DEVICESCAN 行 | root 0644 | 随时; 告警脚本接入前 smartd 只发本机邮件 |
| `alert.curl.example` | `/etc/uten-imp/alert.curl` | root:root 0600 | **等告警通道 (D1)** |
| `uten-alert.sh` | `/usr/local/sbin/uten-alert` | root 0755 | **等 D1**, 同时装 `../units/uten-alert@.service` |
| `uten-host-check.sh` | `/usr/local/sbin/uten-host-check` | root 0755 | **等 D1**, 同时装 `../units/uten-host-check.{service,timer}` |
| `uten-alert-smart.sh` | `/usr/local/sbin/uten-alert-smart` | root 0755 | **等 D1** |
| `uten-alert-md.sh` | `/usr/local/sbin/uten-alert-md` | root 0755 | **等 D1**, `mdadm.conf` 加 `PROGRAM /usr/local/sbin/uten-alert-md` |

告警脚本是常驻在服务器上的运维程序 (不是一次性脚本)。用户此前要求服务器上不留可被人翻到的代码,
是否接受这几只常驻脚本与告警通道一并由用户决定 (治理记录 D1)。未接入前, 各单元里的
`OnFailure=uten-alert@%n.service` 只会在 journal 里记一行 "unit not found", 不影响单元本身。

回归: `deploy/updater/test_simple_units_contract.py` 校验本目录与 `../units/` 的保留期、可写路径、
占位符与脚本语法一致。
