# Uten IMP 服务器交接模板（脱敏版）

> ⚠️ **已随 ADR-060 退役（2026-09-01）**：本文属旧发布链/旧部署链文档，按 [ADR-060](../docs/99-决策记录-ADR/ADR-060-单维护者简化发布链与旧发布链退役.md) 保留作未来引入第二维护者时的参考，不再具有操作效力。现役链见 [deploy/simple/RUNBOOK.zh-CN.md](../simple/RUNBOOK.zh-CN.md)。

<!-- CURRENT-ERP-TEST-SERVER-SCOPE-20260812 -->
> 当前测试主机范围示例：`internal-erp-test`，只登记 PostgreSQL、Spring Boot 和 Flutter ERP Web/Nginx。
> 企业官网登记为“延期到独立云服务器”，不得列入同一主机服务。未来 03:00 维护窗口、02:17 本地备份、
> 自动更新/重启策略必须分字段登记，不能只写“自动”。实时顺序见 `current-test-server-status.zh-CN.md`。

> 文件命名：仓库只保留本模板。真实交接文件使用
> `server-handoff.<environment>.private.md`，放入受控 CMDB/密码管理器或加密文档库，禁止提交 Git。
> 密码、私钥、AccessKey、JWT/PGP/HMAC 密钥不得写入交接文档；这里只登记密钥的保管位置、负责人和轮换日期。
> 目标服务器身份与首次连接的完整验收方法见
> [目标服务器带外身份与访问 authority 清单](target-host-oob-authority.zh-CN.md)。本模板只登记其去敏引用，
> 不在 Git 中保存真实地址、账号、完整公钥或 Host Key 指纹。

## 1. 资产与责任人

| 字段 | 值 |
|---|---|
| 环境 | `internal-test / production / staging / disaster-recovery` |
| 资产编号 | `__ASSET_ID__` |
| 主机名 | `__HOSTNAME__` |
| FQDN/IP/SSH 端口引用 | `__CMDB_NETWORK_REF__` |
| 管理账号与 sudo 边界引用 | `__CMDB_ACCESS_REF__` |
| 机房/机柜 | `__LOCATION__` |
| 业务负责人 | `__OWNER__` |
| 运维负责人/复核人 | `__OPERATOR__ / __REVIEWER__` |
| 变更单 | `__CHANGE_ID__` |
| 最后复核时间 | `__UTC_TIMESTAMP__` |
| 当前环境范围 | `internal-erp-test / production / disaster-recovery` |
| 未来维护窗口 | `03:00 Asia/Shanghai（不代表每日自动重启）` |
| 当前本地备份时间 | `__OBSERVED_TIMER__` |
| 官网状态 | `deferred-to-separate-cloud-host / not-installed-here` |

## 2. 硬件、系统与网络

记录 CPU、内存、UPS、磁盘型号/序列号、RAID 级别、挂载点、文件系统、操作系统版本、内核和 BIOS 来电自启状态。
网络只登记受控资产系统中的引用；仓库副本不得记录真实公网 IP、内网 IP、MAC、VPN PSK 或安全组账号。

### 2.1 带外身份与网络 authority（H01–H12）

| 证据 | 去敏引用/状态 |
|---|---|
| 当前 CMDB 资产元组、采集时间与有效期 | `__CMDB_AUTHORITY_REF__` |
| 物理/BMC 控制台采集的 SSH Host Key 算法、完整公钥与 SHA-256 指纹 | `__HOST_KEY_EVIDENCE_REF__` |
| Host Key 轮换记录或与既有基线一致证明 | `__HOST_KEY_ROTATION_REF__` |
| Admin Key A 指纹、持有人与复核时间 | `__ADMIN_A_REF__` |
| Admin Key B 指纹、持有人与复核时间 | `__ADMIN_B_REF__` |
| 企业 VPN/VLAN/源 CIDR/目标端口与到期时间 | `__NETWORK_AUTHORITY_REF__` |
| 物理/BMC 控制台实际登录与应急恢复记录 | `__CONSOLE_EVIDENCE_REF__` |
| 已泄露旧口令的轮换记录（无口令值） | `__PASSWORD_ROTATION_REF__` |
| 项目专用 `known_hosts` 摘要及带外匹配结果 | `__KNOWN_HOSTS_EVIDENCE_REF__` |
| 只读窗口、变更单、操作人与第二审核人 | `__READ_ONLY_CHANGE_REF__` |

以上材料缺一项即 **NO-GO**。历史 `known_hosts`、`ssh-keyscan`、网络可达或旧聊天记录都不能建立 Host Key
信任；首次 SSH 固定使用项目专用 `known_hosts`、`StrictHostKeyChecking=yes`、`BatchMode=yes` 和禁用密码认证。

必须保存以下只读证据：

```text
uname -a
lsblk -o NAME,MODEL,SERIAL,SIZE,FSTYPE,MOUNTPOINTS
cat /proc/mdstat
findmnt /data
timedatectl status
```

两块 RAID 成员盘必须串行记录 SMART 长测结果，不得同时压测；随后单独记录 RAID `check` 的开始、完成、
`mismatch_cnt` 和中断/重启状态。历史 SMART error log 不得清除或用“overall PASSED”覆盖。

## 3. 身份与秘密

| 身份 | 最小权限 | 保管位置引用 | 轮换日期 |
|---|---|---|---|
| Linux 管理员 A/B | 两把独立 Ed25519 密钥 | `__VAULT_REF__` | `__DATE__` |
| 人员 Git Commit/Tag 签名 | 仅签受审 Git 对象，不登录服务器 | `__GIT_SIGNING_REF__` | `__DATE__` |
| CI/离线 Release 制品签名 | 仅签发布 manifest/channel | `__RELEASE_SIGNING_REF__` | `__DATE__` |
| OSS 发布拉取 | 只读发布前缀 | `__VAULT_REF__` | `__DATE__` |
| OSS 附件应用 | 精确附件权限 | `__VAULT_REF__` | `__DATE__` |
| PostgreSQL `postgres` 应急管理 | 仅受控维护窗口使用 | `__VAULT_REF__` | `__DATE__` |
| PostgreSQL `uten_owner` | NOLOGIN 对象所有者 | `__VAULT_REF__` | `__DATE__` |
| PostgreSQL `uten_migrator` | 独立 oneshot DDL 身份 | `__VAULT_REF__` | `__DATE__` |
| PostgreSQL `uten` | 运行时 DML 身份 | `__VAULT_REF__` | `__DATE__` |
| PostgreSQL `uten_repl` | 仅精确复制来源 | `__VAULT_REF__` | `__DATE__` |
| pgBackRest cipher | 独立密封恢复材料 | `__VAULT_REF__` | `__DATE__` |
| 发布签名公钥 | 只登记 SHA256 指纹 | `__FINGERPRINT__` | `__DATE__` |

不得把真实秘密粘贴到 shell 命令、systemd unit、GitHub 日志、工单正文或本文件。

## 4. 服务与数据边界

- `/opt/uten-imp/releases/<version>`：只读不可变代码制品；`current` 仅为原子符号链接。
- `/etc/uten-imp/server.env`：应用运行环境；不得包含 migrator 凭据。
- `/etc/uten-imp-migrator/`：独立迁移器环境和 DDL 身份。
- `/etc/uten-imp-postgres/`：PostgreSQL 初始化/维护秘密的受控交接目录。
- `/etc/uten-imp-updater/`：GET-only 下载器配置和 updater 信任副本。
- `/etc/uten-imp-release-trust/`：稳定 root-only 恢复验签信任；不得由 updater 写入。
- `/data/postgresql/`：唯一写主库数据。
- 附件权威存储：本生产合同只接受私有、HTTPS、已启用版本控制的 OSS；本地附件目录不得作为正式权威库。
- `/data/backups/pgbackrest/`：本地快速恢复层，不等于异地备份。
<!-- WEBSITE-DATASTORE-MUST-MATCH-REAL-PROVIDER -->
- 企业公网网站当前延期，未来使用独立云主机。官网独立数据存储（当前候选为单节点 SQLite；目标是否迁 PostgreSQL 必须按真实 provider 和 GO 状态登记）及网站媒体属于独立云端系统，不与内网 ERP 主机共用运行账号、数据库或发布链。官网尚未通过签名发布、成对数据恢复和切换验收时必须登记为 **NO-GO**，不得把模板文字当成已完成 PostgreSQL 迁移的证据。

## 5. 当前版本与变更状态

| 项目 | 值 |
|---|---|
| Git commit | `__40_HEX_SHA__` |
| 发布版本 / sequence | `__VERSION__ / __SEQUENCE__` |
| Manifest SHA256 | `__SHA256__` |
| Backend / migrator JAR SHA256 | `__BACKEND_SHA256__ / __MIGRATOR_SHA256__` |
| Flyway 当前/目标 | `__CURRENT__ / __TARGET__` |
| 生产入口 | `closed / maintenance / open` |
| GO/NO-GO | `__STATUS__` |
| 未关闭风险 | `__RISK_REFERENCES__` |

任何 `NO-GO`、缺失证据或未对账迁移都不能用“脚本已运行”替代。

## 6. 备份、恢复与监控

登记本地 repo1 每日 `02:17` 的实际状态；repo2 `03:17` 当前只是 disabled 模板，不能登记成已运行。
未来 03:00 维护开始前必须确认 repo1/expire 已结束并取得数据库维护互斥锁，否则跳过/顺延维护。启用 repo2
前先重新排程，证明 backup、维护、health、apt 和重启不重叠。正式 commissioned 后再登记两个
`Persistent=true` timer 的实际状态，
以及两仓各最近 7 个不同日期成功 full、backup set/WAL 范围、连续 WAL 新鲜度、两仓最新值不落后于 PostgreSQL
`last_archived_wal`、PostgreSQL
`system_identifier`/timeline、canonical Flyway history digest、当前 version/script/checksum 与签名
manifest 逐行一致的 projection digest。另登记 provider WORM/版本控制与独立凭据
证据、外部告警 event+receipt、最近一次 repo2 指定时间点恢复、七类业务对账、真实 RTO/RPO 及详细
backup acceptance receipt SHA-256。repo1 与数据库同在 `/data` 时只能算本地快速恢复层；仓库模板或
health PASS 都不能单独证明异地不可变和 PITR。

## 7. 交接验收

- [ ] 两名管理员分别验证密钥登录；应急控制台可用。
- [ ] H01–H12 全部有效；SSH Host Key 由物理/BMC 控制台带外取得，项目 `known_hosts` 与完整公钥逐字匹配。
- [ ] 首次只读会话固定 `StrictHostKeyChecking=yes`、无密码、无 agent forwarding；密码登录按批准边界关闭。
- [ ] 人员 Git Commit/Tag、Release 制品签名、Admin Key A/B 与 Host Key 五类 authority 没有复用。
- [ ] RAID、`/data` 挂载、PostgreSQL、Nginx、应用和备份 timer 经重启验证。
- [ ] 发布清单与 channel 签名、公钥指纹、防降级 high-water mark 验证通过。
- [ ] staging timer 当前状态和启用依据已登记；未完成保留/配额/告警验收时必须为 disabled。
- [ ] legacy updater/current 退役 evidence 及 activation/boot transaction marker 状态已登记。
- [ ] HTTPS、未知 Host 拒绝、Actuator 404、真实账号最小业务冒烟通过。
- [ ] 数据库 PITR 与附件/秘密恢复材料在隔离环境验证通过。
- [ ] 远程链路断开时云端写请求 fail closed；没有双写、离线队列或公网数据库端口。
- [ ] 所有剩余风险都有负责人、截止时间和变更单。
