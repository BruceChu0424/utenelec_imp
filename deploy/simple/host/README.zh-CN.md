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
- 秘密 (备份仓口令) 不出现在任何命令行参数里: 用 `sudoedit`, 或在服务器上由管道直接生成。
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
| `../../systemd/clamav-uten-imp-unix.socket.conf.example` | `/etc/systemd/system/clamav-daemon.socket.d/uten-unix.conf` | root 0644 | 维护窗口；只保留 `/run/clamav/clamd.ctl`，socket为uten-imp组0660，父目录0755可遍历；应用用原主组并配置Unix路径，移除旧TCP监听后以应用身份验真扫描 |
| `smartd.conf.example` | 替换 `/etc/smartd.conf` 的 DEVICESCAN 行 | root 0644 | 随时; 告警脚本接入前 smartd 只发本机邮件 |
| `uten-host-alert.py` | `/usr/local/libexec/uten-host-alert.py` | root 0755 | 平台告警候选验收后, 与下行同时安装 |
| `start-server.py` | `/usr/local/lib/uten-imp/start-server.py` | root 0755 | 先装脚本, 再更新 `../units/uten-imp.service`; 随应用维护窗口重启生效 |
| `uten-alert.sh` | `/usr/local/sbin/uten-alert` | root 0755 | 同时装 `../units/uten-alert@.service` |
| `uten-host-check.sh` | `/usr/local/sbin/uten-host-check` | root 0755 | 同时装 `../units/uten-host-check.{service,timer}` |
| `uten-alert-smart.sh` | `/usr/local/sbin/uten-alert-smart` | root 0755 | 与主机告警一同安装 |
| `uten-alert-md.sh` | `/usr/local/sbin/uten-alert-md` | root 0755 | `mdadm.conf` 加 `PROGRAM /usr/local/sbin/uten-alert-md` |

告警通道按 2026-10-07 用户要求统一为平台内中央弹窗。主机脚本不发网络请求, 只以 root 写入
`/var/lib/uten-alert/events.json` (目录 root:uten-imp 0750, 文件 0640), 应用只有读取权。
同一维度 6 小时内去重, 保留 7 天、最多 128 条和 64 KiB; 损坏或队列满时保留原证据并报错。
事件只含固定文案与哈希维度, 不保存钩子传入的日志/路径/秘密。应用恢复后补送未送达事件,
发送权限实时解析 `server_status:alert:receive` 与 `notice:read`。应用完全停机期间无法在平台弹窗,
事件会留在本机等待恢复; 这不是外部可用性告警。部署时删除已退役的 `/etc/uten-imp/alert.curl`,
不再配置群机器人。

应用启动器从 systemd 已进入的物理 `releases/vX.Y.Z` 工作目录确定版本，同时把该目录里的真实 JAR
绝对路径和版本传给同一个 JVM。服务器状态页因此显示当前进程实际启动的版本；更新器切换 `current`
或回滚时，旧进程不会提前显示新版本。版本不再依赖人工更新环境变量或项目开发版本号。
非正式版本目录、链接到别处的 JAR、缺失 JAR 均拒绝启动。安装此单元前必须先安装启动脚本；回滚时
一起恢复原单元及启动脚本，应用堆、内存、权限和只读目录限制沿用原单元。

回归: `deploy/updater/test_simple_units_contract.py` 校验本目录与 `../units/` 的保留期、可写路径、
占位符与脚本语法一致。
