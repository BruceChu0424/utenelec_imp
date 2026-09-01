<!-- LEGACY-CLOUD-RUNBOOK-EXECUTION-FORBIDDEN -->
# 阿里云 ECS 灾备设计草案：本地单主库 + 云端热备（当前禁止执行）

> ⚠️ **已随 ADR-060 退役（2026-09-01）**：本文属旧发布链/旧部署链文档，按 [ADR-060](../../docs/99-决策记录-ADR/ADR-060-单维护者简化发布链与旧发布链退役.md) 保留作未来引入第二维护者时的参考，不再具有操作效力。现役链见 [deploy/simple/RUNBOOK.zh-CN.md](../../simple/RUNBOOK.zh-CN.md)。

<!-- CLOUD-DEPLOYMENT-DEFERRED-20260812 -->
> **2026-08-12 负责人范围决定**：当前只建设公司内部 ERP 测试服务器，云端 ERP 应用、热备、自动切换和
> 企业官网均延期。本文件继续作为历史/未来设计草案，不得据此创建 ECS、VPN、云数据库、云角色或自动化。

> **停用边界（2026-08-11）**：本文件保留 2026-08-09 的双站点复制/切换设计证据，不是当前服务器
> commissioning Runbook。第 3–5 节仍包含旧 PostgreSQL 三身份、旧
> `/etc/uten-imp/postgres-secrets`、旧 cloud systemd 和直接 `systemctl enable` 过程，与当前
> 双 JAR、独立 migrator、签名 staging/root activator、持久失败/boot marker 及拆分秘密目录合同不兼容。
> **不得复制执行或用新路径简单替换旧路径。** 如正式采用云端热备，必须另行重写、评审和实机演练
> cloud 激活器、迁移器、信任链、复制身份、备份与回切事务；当前权威本地操作入口是
> [`../operator-guide.zh-CN.md`](../operator-guide.zh-CN.md)。

本手册描述的是一套**单写主库**架构：公司本地 PostgreSQL 是日常唯一可写主库，阿里云 PostgreSQL 是异步物理热备；云端 Spring 应用在链路正常时也写公司主库。它不是双主、离线写队列或自动冲突合并方案。

这不是“只填 `.env` 即可上线”的承诺。只有完成本文的复制、真实故障演练、备份恢复、权限和附件验收后，才可以进入生产。

> **历史状态（2026-08-11）**：Docker 物理复制演练、隔离克隆 V238→V244、远程授权 HTTP 矩阵是
> 历史证据；当时共享工作树文件头为 V255/236（V255 增加附件隔离、扫描、Outbox 与对账状态），但未形成受保护 tag/签名发布，不能反向证明旧演练或
> 目标数据库。真实 ECS/VPN/TLS/权威主库/OSS/PITR/切换回切尚未完成，仍为 **NO-GO**。
> 统一证据与逐项待办见
> [新库上线与首装操作指引](../../docs/99-项目治理/2026-09-01-新库上线与首装操作指引.md)。

> **数据保护后置口径（2026-08-14）**：本草案中的 TLS、pgBackRest cipher 和云盘描述都只是未来配置输入。金额/数量等计算事实保持精确 `NUMERIC`；窄范围 pgcrypto PII 不是全库加密。外部 KMS/HSM/Vault envelope、LUKS2/加密云盘、目标库 PII 回填、加密备份/PITR 和恢复密钥演练均未实施；未确认供应商、密钥授权/轮换、解锁和回滚前，禁止执行。现行决策见 [ADR-037](../../docs/99-决策记录-ADR/ADR-037-数据库数据保护与分级加密.md)。

## 1. 不变量、RPO 与断网行为

```text
公司员工 -> LAN -> 本地 App -> 本地 PostgreSQL 主库（唯一写端）
                                      |
                                      +-- 双隧道 VPN / 专线主 + VPN 备 --> 云端 PostgreSQL 热备

授权远程员工 -> HTTPS -> 云端 App -----+（链路正常时仍连接本地主库）
                            |
                            +-> 与本地共享同一组 OSS staging/final Buckets
```

- 公司到云端链路正常：本地、云端 App 都把业务事务提交到同一个本地主库；不存在跨库合并。
- 链路中断：公司内网继续写本地主库；云端已认证业务请求返回 503，不在云端缓存写入。链路恢复后，热备从复制槽保留的 WAL 继续追平。
- 本方案是**异步复制**。本地事务提交不等待云端确认，因此主库突然永久损坏时，尚未送达云端的已确认事务可能丢失。上线前必须由业务负责人批准一个量化 RPO，例如“正常链路目标 30 秒，告警 60 秒”；不得写“零丢失”。
- 如果业务要求“公司与云端分区时两边都继续写”，应停止使用本手册，另行设计逐业务域冲突语义；不能把物理复制改成双边写入。
- 热备不是备份。误删、恶意更新和损坏会同步到热备，必须另建 PITR 备份链。

PostgreSQL 官方说明：流复制默认异步；故障切换必须防止旧主重新成为写主；复制槽可让 `pg_wal` 无限增长，必须配置上限并监控。

- <https://www.postgresql.org/docs/16/warm-standby.html>
- <https://www.postgresql.org/docs/16/warm-standby-failover.html>
- <https://www.postgresql.org/docs/16/runtime-config-replication.html>

## 2. 上线前资源与网络

> 本节的旧三身份/秘密文件示例仅为历史设计输入，不能用于当前部署。当前本地合同拆分
> `postgres`、`uten_owner`、`uten_migrator`、`uten`、`uten_repl` 及 pgBackRest cipher，并使用
> `/etc/uten-imp-postgres`、`/etc/uten-imp-migrator` 等独立目录；云端模型必须另行评审，禁止文本替换后执行。

1. 公司本地和云端统一 PostgreSQL 16 小版本，并保持升级节奏一致。
2. 云端 ECS 与 OSS 同 region；PostgreSQL 数据盘、WAL/日志容量和 IOPS 分开核算。
3. 公司到阿里云至少使用 IPsec **双隧道**；更高要求使用“专线主 + VPN 备”。两条路径都要配置路由、健康探测和季度切换演练。参考：<https://www.alibabacloud.com/help/en/vpn/sub-product-ipsec-vpn/user-guide/create-and-manage-an-ipsec-vpn-connection-in-dual-tunnel-mode>。
4. PostgreSQL 5432 只允许云端 App/热备的精确私网地址，经 VPN/专线访问；不得开放公网。ECS 安全组和主机防火墙都要限制来源。
5. PostgreSQL 跨站点连接必须启用 TLS。主库证书 SAN 应包含稳定的内部 DNS 名，例如 `pg-primary.imp.internal`，客户端使用 `sslmode=verify-full`；不要用会绕过主机名校验的 `sslmode=require` 代替。
6. 准备三个不同的 PostgreSQL 密码：
   - admin：仅本地主库维护使用，不开放远程 HBA；
   - replication：只给物理复制角色；
   - app：只给 Spring 应用角色。
7. 把密码放入主机密钥管理或权限为 `0600` 的独立文件，不写进命令行、Git、shell history、systemd 单元或日志。

示例目录，仅作为路径约定：

```bash
install -d -m 0700 -o postgres -g postgres /etc/uten-imp/postgres-secrets
# 由密钥管理系统写入；以下三个文件内容必须不同，且至少 16 字符
chmod 0600 /etc/uten-imp/postgres-secrets/{admin,repl,app}.password
chown postgres:postgres /etc/uten-imp/postgres-secrets/{admin,repl,app}.password
```

## 3. 准备公司本地主库

> **历史步骤，禁止执行。** 当前权威 V238→签名目标版本尚无受审生产切换入口；不得用本节旧脚本、
> 角色或 HBA 命令修改现有权威库。

### 3.1 先确认连接的是哪一个集群

在本地主库执行并记录变更单：

```sql
SELECT version(), pg_is_in_recovery();
SHOW data_directory;
SHOW hba_file;
SHOW ssl;
```

`pg_is_in_recovery()` 必须为 `false`，`ssl` 必须为 `on`。把查询返回的**精确绝对路径**传给脚本，不得猜 `/var/lib/postgresql/data`。Debian/Ubuntu 常见路径是 `/var/lib/postgresql/16/main`，但仍以查询结果为准。

合并 `deploy/postgres/primary.conf.example` 中的 TLS/复制设置，或让下方脚本通过 `ALTER SYSTEM` 设置复制参数。生产默认值为：

```text
wal_keep_size=2GB
max_slot_wal_keep_size=16GB
synchronous_standby_names=''   # 明确异步
```

`16GB` 不是通用容量答案。应按“高峰 WAL 字节/小时 × 允许断链小时数 × 至少 1.5 安全系数”核算，同时保证主库磁盘预留；容量不足时复制槽会失效，副本必须重新做 base backup。

### 3.2 本机运行主库准备脚本

脚本只允许连接经过路径核对的主库，创建/收敛 app 与 replication 角色、创建物理槽、写入精确 HBA 规则并备份原 HBA。密码只从文件读入。

```bash
sudo -u postgres env \
  PRIMARY_PGDATA=/var/lib/postgresql/16/main \
  PRIMARY_PG_HBA_FILE=/etc/postgresql/16/main/pg_hba.conf \
  PGHOST=pg-primary.imp.internal \
  PGPORT=5432 \
  PGDATABASE=postgres \
  PGUSER=postgres \
  PGSSLMODE=verify-full \
  PGSSLROOTCERT=/etc/uten-imp/tls/company-root-ca.crt \
  ADMIN_PASSWORD_FILE=/etc/uten-imp/postgres-secrets/admin.password \
  REPL_PASSWORD_FILE=/etc/uten-imp/postgres-secrets/repl.password \
  APP_PASSWORD_FILE=/etc/uten-imp/postgres-secrets/app.password \
  REPLICATION_CIDR=10.8.0.10/32 \
  CLOUD_APP_CIDR=10.8.0.20/32 \
  ON_PREM_REPLICA_CIDR=10.20.0.10/32 \
  ON_PREM_APP_CIDR=10.20.0.20/32 \
  REPL_USER=uten_repl \
  APP_USER=uten \
  APP_DATABASE=uten_imp \
  SLOT_NAME=uten_cloud_replica \
  MAX_SLOT_WAL_KEEP_SIZE=16GB \
  bash deploy/postgres/prepare-primary.sh
```

注意：通过 `bash ...` 调用，不依赖 Git 执行位。四个 CIDR 都必须替换为真实 VPN/专线地址：云端副本、云端 App、灾备时重建为副本的本地主机、本地 App。脚本拒绝远程 admin HBA；`deploy/postgres/pg_hba-replication.conf.example` 给出了正向与反向拓扑所需的 `hostssl` 规则。

HBA 按“第一条匹配规则”生效。脚本会校验新文件可解析，但运维仍必须审查前置规则，移除会先匹配云端来源的宽泛 `host all all 0.0.0.0/0`/`::0/0`，不能只在文件末尾追加严格规则就认为已经收口：

```sql
SELECT rule_number, type, database, user_name, address, auth_method, error
FROM pg_hba_file_rules
ORDER BY rule_number;
```

若脚本报告 `RESTART REQUIRED`，通过受控维护操作重启**刚才核对的**集群，例如：

```bash
sudo pg_ctlcluster 16 main restart
```

重启后必须验证：

```sql
SELECT pg_is_in_recovery();
SHOW wal_level;
SHOW wal_keep_size;
SHOW max_slot_wal_keep_size;
SHOW synchronous_standby_names;
SELECT slot_name, slot_type, active, wal_status, restart_lsn
FROM pg_replication_slots
WHERE slot_name = 'uten_cloud_replica';
```

## 4. 克隆阿里云热备

> **历史演练步骤，禁止用于目标环境。** 只有新的云端灾备变更完成身份、TLS、签名迁移、备份恢复、
> fencing 和回切事务评审后，才可形成新的可执行 Runbook。

### 4.1 安装和路径核对

在 ECS 安装 PostgreSQL 16 客户端/服务端工具（必须包含 `pg_verifybackup`）和公司根证书。还要为云端 PostgreSQL 配置 SAN 含 `pg-standby.imp.internal` 的独立服务端证书；若物理备份继承的配置引用本地主机证书路径，应在启动前把云端证书安全放到相同路径，或在受控的云端 `postgresql.conf` 中改为云端路径。先查本机集群路径：

```bash
pg_lsclusters
sudo -u postgres test -f /var/lib/postgresql/16/main/PG_VERSION
```

`clone-replica.sh` 有以下安全行为：

- 必须同时传 `REPLICA_PGDATA` 与完全相同的 `CONFIRM_REPLICA_PGDATA`；
- 拒绝 root、符号链接、宽泛目录和 PGDATA 本身是 mount point 的情况；
- 先在同级 staging 目录完成 `pg_basebackup` 和 `pg_verifybackup`；
- `pg_basebackup --wal-method=stream` 使用自己的临时槽，不占用永久 `SLOT_NAME`；健康旧副本在 staging 校验完成前继续占用永久槽，最终停机切换后新副本才接管同一个永久槽；
- 停止经过路径核对的集群后，将旧 PGDATA 重命名保留，再安装新副本；
- 新副本启动失败时自动恢复旧 PGDATA；
- replication 密码保存为新 PGDATA 内的 `standby.pgpass`（0600），不写入 `primary_conninfo`。

PGDATA 若直接是独立磁盘 mount point，先把磁盘挂到父目录，再用其子目录作为 PGDATA；脚本不会跨 mount point 替换目录。
PGDATA 父文件系统还必须能同时容纳“旧副本 + 新 staging/回滚副本”，并预留 WAL 与运行空间；克隆前应按至少两份当前数据库体积做容量检查。

### 4.2 执行克隆

```bash
sudo -u postgres env \
  PRIMARY_HOST=pg-primary.imp.internal \
  PRIMARY_PORT=5432 \
  PRIMARY_SSLMODE=verify-full \
  PRIMARY_SSLROOTCERT=/etc/uten-imp/tls/company-root-ca.crt \
  REPL_USER=uten_repl \
  REPL_PASSWORD_FILE=/etc/uten-imp/postgres-secrets/repl.password \
  SLOT_NAME=uten_cloud_replica \
  APPLICATION_NAME=uten_cloud_replica \
  APP_DATABASE=uten_imp \
  REPLICA_PGDATA=/var/lib/postgresql/16/main \
  CONFIRM_REPLICA_PGDATA=/var/lib/postgresql/16/main \
  REPLICA_SERVICE_MANAGER=pg_ctlcluster \
  REPLICA_CLUSTER_VERSION=16 \
  REPLICA_CLUSTER_NAME=main \
  bash deploy/postgres/clone-replica.sh
```

脚本成功后旧目录会以 `.preclone.<UTC timestamp>` 保留。只有完成本节全部验证并确认还有独立备份后，才由运维在变更单中精确删除它。不要在旧副本仍运行时手工删除或重建永久复制槽；健康旧副本的在线 staging 重克隆不需要释放该槽。

### 4.3 准备云端实际 HBA

Debian/Ubuntu 通常把 `hba_file` 放在 `/etc/postgresql/...`，该文件不属于 PGDATA，也不会被 `pg_basebackup` 复制。副本启动后先执行 `SHOW data_directory; SHOW hba_file;`，把精确返回路径传给专用脚本；脚本会拒绝主库、路径不一致、非 PostgreSQL 16、TLS 未启用和既有 HBA 语法错误：

```bash
sudo -u postgres env \
  REPLICA_PGDATA=/var/lib/postgresql/16/main \
  REPLICA_PG_HBA_FILE=/etc/postgresql/16/main/pg_hba.conf \
  REPLICA_VERIFY_SOCKET=/var/run/postgresql \
  REPLICA_VERIFY_PORT=5432 \
  CLOUD_APP_CIDR=10.8.0.20/32 \
  ON_PREM_REPLICA_CIDR=10.20.0.10/32 \
  ON_PREM_APP_CIDR=10.20.0.20/32 \
  REPL_USER=uten_repl \
  APP_USER=uten \
  APP_DATABASE=uten_imp \
  bash deploy/postgres/prepare-standby-hba.sh
```

这三条 host 必须同时受 ECS 安全组、主机防火墙和 VPN/专线路由限制；云端 PostgreSQL 5432 不得开放公网。完成后检查 `pg_hba_file_rules` 顺序，并从云端 App 主机以 `pg-standby.imp.internal` + `sslmode=verify-full` 做真实 app-role 连接。若 App 与 PostgreSQL 同一 ECS，可把 `CLOUD_APP_CIDR` 设为实际连接使用的回环 /32 或 ECS 私网 /32，但 DNS 解析、证书 SAN 与 HBA 必须三者一致。

### 4.4 真实回放验证

主库：

```sql
SELECT application_name, state, sync_state, client_addr,
       sent_lsn, write_lsn, flush_lsn, replay_lsn,
       pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS replay_gap
FROM pg_stat_replication
WHERE application_name = 'uten_cloud_replica';
```

副本：

```sql
SELECT pg_is_in_recovery(), pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn(),
       now() - pg_last_xact_replay_timestamp() AS replay_delay;
```

随后在受控测试业务记录上做真实 insert、update、delete，逐项验证副本的业务值、审计记录和删除结果；不能只看 `state=streaming`。

## 5. 云端应用环境

> **历史配置，禁止部署。** 旧 cloud unit 没有当前 app/migrator validator、签名激活器和持久故障/
> boot marker；本节不能作为云端应用上线或开机自启依据。

云端必须同时启用 `cloud` 与 `prod` profile，不能只启用 `cloud` 而跳过生产 HTTPS/Swagger 约束。`UTEN_DB_URL` 是 `prod` profile 的必填占位符，设为与 primary 相同的安全 URL。下面仅列出云端差异和关键共享项，不是生产变量完整清单；其余短信、审计、限流、密钥版本和监控项仍须逐项对照 `server/.env.example`，缺失时不得上线。

`/etc/uten-imp/server-cloud.env` 权限设为 `0640`，仅服务用户与受控运维组可读：

```env
UTEN_PROFILE=cloud,prod

# prod 占位符与 cloud 双数据源；跨站点使用 verify-full。
UTEN_DB_URL=jdbc:postgresql://pg-primary.imp.internal:5432/uten_imp?sslmode=verify-full&sslrootcert=/etc/uten-imp/tls/company-root-ca.crt&connectTimeout=5&tcpKeepAlive=true
UTEN_DB_PRIMARY_URL=jdbc:postgresql://pg-primary.imp.internal:5432/uten_imp?sslmode=verify-full&sslrootcert=/etc/uten-imp/tls/company-root-ca.crt&connectTimeout=5&tcpKeepAlive=true
UTEN_DB_REPLICA_URL=jdbc:postgresql://pg-standby.imp.internal:5432/uten_imp?sslmode=verify-full&sslrootcert=/etc/uten-imp/tls/company-root-ca.crt&connectTimeout=5&tcpKeepAlive=true
UTEN_DB_USER=uten
UTEN_DB_PASSWORD=__APP_ROLE_PASSWORD_FROM_SECRET_MANAGER__

# 必须与本地生产 App 完全相同，否则自动切换后 token/密文/HMAC 不兼容。
UTEN_JWT_ISSUER=uten-imp-production
UTEN_JWT_SECRET=__SAME_AS_ON_PREM__
UTEN_PGP_MASTER_KEY=__SAME_AS_ON_PREM__
UTEN_PGP_KEY_VERSION=__SAME_AS_ON_PREM__
UTEN_HMAC_KEY=__SAME_AS_ON_PREM__

UTEN_CORS_ORIGINS=https://imp.example.com
UTEN_REQUIRE_HTTPS=true
UTEN_TRUSTED_PROXY_REGEX=127\..*|::1

UTEN_STORAGE_PROVIDER=oss
UTEN_OSS_USE_INSTANCE_ROLE=true
UTEN_OSS_ROLE_NAME=uten-imp-oss-role
UTEN_OSS_ENDPOINT=https://oss-cn-__REGION__.aliyuncs.com
UTEN_OSS_STAGING_BUCKET=__SAME_UNVERSIONED_STAGING_BUCKET_AS_ON_PREM__
UTEN_OSS_FINAL_BUCKET=__SAME_VERSIONED_FINAL_BUCKET_AS_ON_PREM__
UTEN_OSS_KEY_PREFIX=attachments/
UTEN_OSS_REQUIRE_VERSIONING=true
```

本地生产 App 也必须使用同一组 OSS Buckets：staging 必须 Versioning=Off 并由 POST policy 禁止覆盖，final 必须 Versioning=Enabled 且只能由服务端提升写入；两者必须不同。不能让本地写磁盘而只让云端写 OSS，否则数据库只复制附件元数据，文件本体不会到云端。本地若不在阿里云上，通过密钥管理注入一个最小权限 RAM 用户的 AK/SK；云端使用 ECS 实例 RAM 角色，不落长期 AK/SK。

### 5.1 一次性安装 cloud systemd 与 Nginx

> **历史步骤，禁止执行。** 下列 direct install/enable 命令绕过当前签名激活器、独立 migrator 和
> activation/boot failure marker。仓库尚未实现等价的 cloud activator；保留此段只用于重写时识别
> 旧依赖，不能用于目标 ECS 或本地服务器。

以下命令以 Debian/Ubuntu 为例。证书必须先由受控证书流程下发；环境文件必须由密钥管理系统写入，不能把秘密粘贴进 shell history：

```bash
sudo apt-get update
sudo apt-get install -y openjdk-21-jre-headless nginx curl jq

getent group uten-imp >/dev/null || sudo groupadd --system uten-imp
id -u uten-imp >/dev/null 2>&1 || \
  sudo useradd --system --gid uten-imp --home-dir /nonexistent --shell /usr/sbin/nologin uten-imp
sudo install -d -m 0750 -o root -g uten-imp /etc/uten-imp
sudo install -d -m 0755 -o root -g root /opt/uten-imp/releases
sudo chown root:uten-imp /etc/uten-imp/server-cloud.env
sudo chmod 0640 /etc/uten-imp/server-cloud.env

sudo install -m 0644 deploy/cloud/uten-imp-cloud.service.example \
  /etc/systemd/system/uten-imp-cloud.service
```

Nginx 模板必须先在非激活路径替换全部占位符。变量只允许 DNS host 或绝对路径，避免把 shell/sed 元字符带入配置：

```bash
UTEN_CLOUD_DOMAIN='imp.example.com'
UTEN_OSS_PUBLIC_HOST='company-attachments.oss-cn-hangzhou.aliyuncs.com'
UTEN_TLS_CERT_PATH='/etc/nginx/tls/cloud-fullchain.pem'
UTEN_TLS_KEY_PATH='/etc/nginx/tls/cloud-privkey.pem'

[[ "$UTEN_CLOUD_DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || exit 1
[[ "$UTEN_OSS_PUBLIC_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || exit 1
[[ "$UTEN_TLS_CERT_PATH" =~ ^/[A-Za-z0-9._/-]+$ ]] || exit 1
[[ "$UTEN_TLS_KEY_PATH" =~ ^/[A-Za-z0-9._/-]+$ ]] || exit 1

sudo install -m 0644 deploy/cloud/nginx-cloud.conf.example \
  /etc/nginx/uten-imp-cloud.conf.candidate
sudo sed -i \
  -e "s|__CLOUD_DOMAIN__|$UTEN_CLOUD_DOMAIN|g" \
  -e "s|__OSS_PUBLIC_HOST__|$UTEN_OSS_PUBLIC_HOST|g" \
  -e "s|__TLS_CERT_PATH__|$UTEN_TLS_CERT_PATH|g" \
  -e "s|__TLS_KEY_PATH__|$UTEN_TLS_KEY_PATH|g" \
  /etc/nginx/uten-imp-cloud.conf.candidate
if sudo grep -nE '__[A-Z0-9_]+__' /etc/nginx/uten-imp-cloud.conf.candidate; then
  echo 'ERROR: unresolved Nginx placeholder' >&2
  exit 1
fi
sudo test -r "$UTEN_TLS_CERT_PATH"
sudo test -r "$UTEN_TLS_KEY_PATH"
sudo install -m 0644 /etc/nginx/uten-imp-cloud.conf.candidate \
  /etc/nginx/conf.d/uten-imp-cloud.conf
sudo nginx -t
sudo systemctl daemon-reload
sudo systemctl enable uten-imp-cloud.service nginx
```

本地主机也必须安装受监督服务并从精确 LAN/VPN 边界生成 Nginx 配置，不能直接部署模板中的占位符：

```bash
sudo apt-get update
sudo apt-get install -y openjdk-21-jre-headless nginx curl jq
getent group uten-imp >/dev/null || sudo groupadd --system uten-imp
id -u uten-imp >/dev/null 2>&1 || \
  sudo useradd --system --gid uten-imp --home-dir /nonexistent --shell /usr/sbin/nologin uten-imp
sudo install -d -m 0750 -o root -g uten-imp /etc/uten-imp
sudo install -d -m 0755 -o root -g root /opt/uten-imp/releases
sudo chown root:uten-imp /etc/uten-imp/server.env
sudo chmod 0640 /etc/uten-imp/server.env
sudo install -m 0644 deploy/systemd/uten-imp.service.example \
  /etc/systemd/system/uten-imp.service

UTEN_LOCAL_DOMAIN='imp-lan.example.internal'
UTEN_OFFICE_CIDR='10.20.0.0/24'
UTEN_VPN_CIDR='10.30.0.0/24'
UTEN_OSS_PUBLIC_HOST='company-attachments.oss-cn-hangzhou.aliyuncs.com'
UTEN_TLS_CERT_PATH='/etc/nginx/tls/local-fullchain.pem'
UTEN_TLS_KEY_PATH='/etc/nginx/tls/local-privkey.pem'

[[ "$UTEN_LOCAL_DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || exit 1
[[ "$UTEN_OFFICE_CIDR" =~ ^[0-9A-Fa-f:.]+/[0-9]{1,3}$ ]] || exit 1
[[ "$UTEN_VPN_CIDR" =~ ^[0-9A-Fa-f:.]+/[0-9]{1,3}$ ]] || exit 1
[[ "$UTEN_OSS_PUBLIC_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || exit 1
[[ "$UTEN_TLS_CERT_PATH" =~ ^/[A-Za-z0-9._/-]+$ ]] || exit 1
[[ "$UTEN_TLS_KEY_PATH" =~ ^/[A-Za-z0-9._/-]+$ ]] || exit 1

sudo install -m 0644 deploy/nginx/uten-imp.conf.example \
  /etc/nginx/uten-imp-local.conf.candidate
sudo sed -i \
  -e "s|__LOCAL_DOMAIN__|$UTEN_LOCAL_DOMAIN|g" \
  -e "s|__OFFICE_CIDR__|$UTEN_OFFICE_CIDR|g" \
  -e "s|__VPN_CIDR__|$UTEN_VPN_CIDR|g" \
  -e "s|__OSS_PUBLIC_HOST__|$UTEN_OSS_PUBLIC_HOST|g" \
  -e "s|__TLS_CERT_PATH__|$UTEN_TLS_CERT_PATH|g" \
  -e "s|__TLS_KEY_PATH__|$UTEN_TLS_KEY_PATH|g" \
  /etc/nginx/uten-imp-local.conf.candidate
if sudo grep -nE '__[A-Z0-9_]+__' /etc/nginx/uten-imp-local.conf.candidate; then
  echo 'ERROR: unresolved Nginx placeholder' >&2
  exit 1
fi
sudo test -r "$UTEN_TLS_CERT_PATH"
sudo test -r "$UTEN_TLS_KEY_PATH"
sudo install -m 0644 /etc/nginx/uten-imp-local.conf.candidate \
  /etc/nginx/conf.d/uten-imp-local.conf
sudo nginx -t
sudo systemctl daemon-reload
sudo systemctl enable uten-imp.service nginx
```

`nginx -t` 失败时禁止 reload/start，先恢复上一份已验收配置。若前置有 WAF/SLB，必须另外配置其精确源地址、real-IP 信任链和安全组；没有经过真实链路验证时，Nginx 看到的 `$remote_addr` 不能被当作最终客户端地址。

### 5.2 安装不可变发布制品

当前签名制品只允许 `server/`、`web/`、`sbom/` 和根 `SHA256SUMS`；明确禁止携带
`deploy/` 或任何由 root 执行的脚本。服务器只可使用
[`deploy/release/README.md`](../release/README.md) 定义的非特权 staging 与显式 root
激活器。不得手工复制版本目录、从 staging 移动文件、就地生成校验和或直接改写
`current`。watchdog 由安装阶段固定到 `/usr/local/libexec/uten-imp/`，不属于远程制品。

本地和云端若要接收同一版本，必须分别安装并验证相同的发布公钥、签名 manifest、
release sequence 和 Flyway migration-set digest。当前云端激活/编排尚未完成真实环境
演练，因此本节不能作为云端上线授权。

### 5.3 维护窗口全停切换；禁止滚动混跑

当前 token/claim 没有旧版兼容 writer，本地与云端**禁止新旧 JAR 滚动混跑**。
发布和回滚必须在同一维护窗口排空请求、清退会话，并让两个站点最终运行相同的
签名版本。唯一允许执行 Flyway 的本地主机先由签名激活器完成迁移与严格健康检查；
随后必须用受控 DBA 连接确认云端副本已回放到相同的 `installed_rank/version/checksum`
和签名 migration-set digest，云端才能启动同版本。

旧版“手工 `ln -s`/`mv current`”步骤已停用。云端尚未实现与本地激活器等价的签名复验、
反降级、全停编排、失败关闭入口和开机自启恢复之前，双站点发布仍为 **NO-GO**。
完整人工审批和本地主机命令见 [`operator-guide.zh-CN.md`](../operator-guide.zh-CN.md)。

## 6. OSS 生产门禁

应用附件 Bucket 与数据库备份 Bucket 分离，且都不得授予 `AliyunOSSFullAccess`。附件确认会把精确 OSS `versionId` 固化到数据库，后续校验、下载和授权删除都必须操作该版本；因此应用运行身份按实际代码路径限定为对象级 `oss:PutObject`、`oss:GetObject`、`oss:GetObjectVersion`、`oss:DeleteObject`、`oss:DeleteObjectVersion`，以及 Bucket 级 `oss:GetBucketVersioning`。只有确实运行受控孤儿扫描时才另授 Bucket 级 `oss:ListObjects`，不能为“方便排障”常驻授予 `oss:*`。数据库备份身份只允许独立备份 prefix。

版本清单与恢复使用独立的临时运维身份：Bucket 级 `oss:ListObjectVersions` + 对象级 `oss:GetObjectVersion`，若要把历史版本复制为新当前版本再按审批临时增加 `oss:PutObject`。`oss:DeleteObjectVersion` 是永久删除权限，不应授给只读审计/恢复身份；清理身份若确需该权限，必须双人审批、限定 prefix/时间窗并留审计。官方权限表与版本行为见：<https://www.alibabacloud.com/help/en/oss/user-guide/authorization-syntax-and-elements>、<https://www.alibabacloud.com/help/en/oss/developer-reference/getobject>、<https://www.alibabacloud.com/help/en/oss/developer-reference/rm>。

上线前完成：

切换云端前目标库 `SELECT count(*) FROM attachments WHERE storage_version IS NULL` 必须为 0；非 0 行必须先隔离，并在人工核对 OSS 精确版本与服务端哈希后回填，不得回退读取 current 版本。

1. 同一个应用 Bucket、同一个 `attachments/` prefix；本地和云端分别用独立身份。
2. 开启 Bucket 版本控制，保留误删/覆盖恢复能力：<https://www.alibabacloud.com/help/en/oss/user-guide/overview-78/>。
3. CORS 只允许实际 Web origin；方法按功能精确开放 `PUT/GET/HEAD`，header 仅登记真实浏览器预检中出现的 `Content-Type` 等必要项，禁止 `*` origin 搭配凭据。生产启用版本控制时**不得要求或放行 `x-oss-forbid-overwrite` 作为完整性门禁**；该 header 只用于非版本控制的开发 Bucket。参考：<https://www.alibabacloud.com/help/en/oss/user-guide/configure-cross-origin-resource-sharing>。
4. 预签名 URL 保持短有效期。版本控制下重放同一 PUT 会生成另一个 `versionId`，不会以“第二次 PUT 必须冲突”作为正确性条件；必须真实验证“首次上传并确认版本 A → 重放生成版本 B → 业务下载仍按数据库固定的版本 A 返回”，并覆盖错误 Content-Type、过期 URL、跨用户访问和并发 confirm/replay。
5. 未确认上传只能在独立 prefix/tag、超过批准宽限期且完成 DB 对账后清理；监控“DB 元数据存在但对象/精确 versionId 缺失”和“对象版本存在但 DB 无引用”两类孤儿。
6. **不得用 Bucket 生命周期或批量脚本无对账清理任何已确认 `storage_key + versionId`**，也不得仅因版本不是 current、年龄较旧或出现 delete marker 就永久删除。任何 confirmed 版本清理必须先与数据库、审计、业务留存/法务保留和可恢复备份逐项对账并双人批准；在此闭环未实现前，历史版本永久清理保持关闭。
7. 定期用临时恢复身份演练按 `versionId` 读取、校验哈希/元数据并恢复被覆盖或软删除对象；不得用拥有永久删除权的日常应用身份代替恢复身份。

当前预签名 PUT 仍不能在 OSS 接收字节前证明内容长度；上线还必须在真实 OSS 上完成 PostPolicy `content-length-range` 或等价的服务端大小硬门禁，并把未确认对象放入可隔离的 staging/final 流程，接入恶意内容扫描和受控转正。删除必须改为数据库状态机 + outbox worker 的幂等外部删除，不能把“数据库删除 + OSS 调用”宣称为跨系统原子事务；同时限制用户/单据 pending 数量与总字节，对过期未确认对象做有审计的孤儿对账和清理。上述大小、隔离、扫描、删除状态机、配额/孤儿任一未闭环时，附件生产状态保持 **NO-GO**，不能因 `versionId` 已固定而放行。

## 7. Flutter 客户端构建

原生客户端必须把两个受控地址固化进构建产物，不能依赖员工手工输入任意主机：

```bash
flutter build windows --release \
  --dart-define=API_BASE_URL=https://imp-lan.example.internal/api \
  --dart-define=CLOUD_API_BASE_URL=https://imp.example.com/api

flutter build apk --release \
  --dart-define=API_BASE_URL=https://imp-lan.example.internal/api \
  --dart-define=CLOUD_API_BASE_URL=https://imp.example.com/api
```

Web Release 使用同源 `/api`，不得照抄原生命令或传入绝对 `API_BASE_URL`/`CLOUD_API_BASE_URL`：

```bash
flutter build web --release --no-pub --no-web-resources-cdn \
  --dart-define=APP_VERSION=__RELEASE_VERSION__
```

同一个受控 Web 域名应通过 split DNS/内外网路由分别落到本地或云端站点；两个站点都必须以同一 origin 提供静态文件，并把 `/api` 反向代理到各自后端。上线验收需确认生成产物没有绝对 API 端点，并分别在公司网络与外网做真实浏览器同源请求；不能假设原生客户端行为等同浏览器。

当前客户端源码已实现两个编译期端点及 Release 任意 host 拒绝。原生构建后仍要从**最终签名产物**做
配置验收，确认 `CLOUD_API_BASE_URL` 被读取且两个 host 都是预期值；产物不符即 NO-GO，不能退回
“让用户手填 HTTPS URL”。此外必须先补登录页“恢复自动选择”入口，避免已保存仅本地/仅云端后
换网或撤权造成未登录自锁；恢复只能在两个构建内可信 host 之间选择。

本地与云端使用同一 `UTEN_JWT_ISSUER`/secret 是无缝切换的必要条件，但不是充分条件；仍需真实验证未授权账号登录/refresh、授权账号、本地访问、在线撤权和链路中断矩阵。

## 8. 监控、容量与告警

至少每分钟采集：

```sql
-- 主库：槽积压和槽状态
SELECT slot_name, active, wal_status, restart_lsn,
       pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS retained_bytes
FROM pg_replication_slots
WHERE slot_name = 'uten_cloud_replica';

-- 主库：发送/回放差距
SELECT application_name, state, sync_state,
       pg_wal_lsn_diff(sent_lsn, replay_lsn) AS replay_gap_bytes,
       now() - reply_time AS last_reply_age
FROM pg_stat_replication
WHERE application_name = 'uten_cloud_replica';

-- 主库：WAL 目录与磁盘由主机监控同时采集
SELECT pg_size_pretty(sum(size))
FROM pg_ls_waldir();
```

告警至少包括：复制连接断开、回放延迟超过 RPO、槽 `wal_status` 非 `reserved/extended`、积压达到 `max_slot_wal_keep_size` 的 50%/75%/90%、数据盘或 WAL 盘 70%/80%/90%。达到上限导致槽丢失后，不得手工推进槽伪装成功，必须重新克隆副本。

### 8.1 `unreserved/lost` 槽的受控重建

健康旧副本正在 `streaming` 时，永久槽应为 `active=true`，直接运行 `clone-replica.sh` 即可；base backup 使用临时槽，不能先停旧副本或删除永久槽。只有下列查询确认永久槽已经 `unreserved/lost`、所需 WAL 不可取得时，才进入失效槽路径：

```sql
SELECT slot_name, slot_type, active, wal_status, restart_lsn
FROM pg_replication_slots
WHERE slot_name = 'uten_cloud_replica';
```

处理顺序必须为：

1. 停止并 fence 旧副本，确认它不会再次以旧 `primary_slot_name` 接入；保留其 PGDATA 作为取证，不得清空。
2. 再查一次槽，`active` 必须为 `false`。若仍为 `true`，停止操作并查明占用连接；不得强制 drop active slot。
3. 原样重跑第 3.2 节完整 `prepare-primary.sh` 命令，仅额外加入 `RECREATE_INVALID_SLOT=yes`。脚本只会在槽为物理、inactive 且 `wal_status=unreserved/lost` 时 drop/recreate，并立即预留 WAL；其他状态一律不做破坏性重建。
4. 紧接着按第 4.2 节运行 `clone-replica.sh`。若克隆或启动失败，保持云端业务不可用，不能把旧副本伪装为已追平。
5. 完成第 4.4 节的真实增删改回放和业务/审计对账后，才关闭事故。

```bash
# 这是加入第 3.2 节 sudo -u postgres env 参数列表的显式破坏性确认；
# 不得长期写入 profile 或 systemd 环境。
RECREATE_INVALID_SLOT=yes
```

每月测一次链路断开后继续写、恢复后追平；每季度测双隧道/专线切换；每半年完成一次完整灾备切换和恢复原拓扑。

## 9. 主库故障切换（人工、双人复核）

PostgreSQL 不提供完整的自动 fencing。以下顺序不可跳过：

1. 宣布事故，停止发布和 schema 变更，冻结所有仍可能连接旧主的应用写流量。
2. 从公司、云端和独立监控三处确认故障；记录主库最后已知 LSN、云端 replay LSN 和预计数据损失。
3. **先 fence 旧主**：关闭主机电源或隔离其 PostgreSQL 存储与全部网络路由，并由第二人确认。仅“ping 不通”不算 fencing。
4. 业务负责人接受本次异步 RPO 后，在云端执行：

   ```sql
   SELECT pg_promote(true, 60);
   SELECT pg_is_in_recovery(); -- 必须 false
   ```

5. 在恢复业务流量前，先查询并记录云端新主的 `SHOW data_directory; SHOW hba_file;`。不要假设 `/etc` 下的 HBA 会被 `pg_basebackup` 复制；用云端**实际路径**运行下列 fail-closed 准备命令，写入本地 App/HBA、创建反向物理槽 `uten_onprem_replica` 并立即预留 WAL。四个示例 CIDR 必须换成真实私网 /32（或 /128）：

   ```bash
   sudo -u postgres env \
     PRIMARY_PGDATA=/var/lib/postgresql/16/main \
     PRIMARY_PG_HBA_FILE=/etc/postgresql/16/main/pg_hba.conf \
     PGHOST=pg-standby.imp.internal \
     PGPORT=5432 \
     PGDATABASE=postgres \
     PGUSER=postgres \
     PGSSLMODE=verify-full \
     PGSSLROOTCERT=/etc/uten-imp/tls/company-root-ca.crt \
     ADMIN_PASSWORD_FILE=/etc/uten-imp/postgres-secrets/admin.password \
     REPL_PASSWORD_FILE=/etc/uten-imp/postgres-secrets/repl.password \
     APP_PASSWORD_FILE=/etc/uten-imp/postgres-secrets/app.password \
     REPLICATION_CIDR=10.20.0.10/32 \
     CLOUD_APP_CIDR=10.8.0.20/32 \
     ON_PREM_REPLICA_CIDR=10.20.0.10/32 \
     ON_PREM_APP_CIDR=10.20.0.20/32 \
     REPL_USER=uten_repl \
     APP_USER=uten \
     APP_DATABASE=uten_imp \
     SLOT_NAME=uten_onprem_replica \
     APPLICATION_NAME=uten_onprem_replica \
     MAX_SLOT_WAL_KEEP_SIZE=16GB \
     bash deploy/postgres/prepare-primary.sh
   ```

   若脚本报告 `RESTART REQUIRED`，必须在入口仍关闭时受控重启云端 PostgreSQL 并重新验证 `pg_is_in_recovery()=false`。随后确认 `pg_hba_file_rules` 无 error、反向槽为 physical 且未 lost，并把云端安全组/主机防火墙 5432 只开放给本地 App 与待重建本地主机的精确私网地址。不得开放公网或 admin HBA。
6. 临时把云端 `UTEN_DB_PRIMARY_URL` 与 `UTEN_DB_URL` 改为 `pg-standby.imp.internal` 新主；当前没有第二副本时，`UTEN_DB_REPLICA_URL` 可临时指向同一实例，但必须记录“无热备”高风险并尽快重建。把本地 App 的 `UTEN_DB_URL` 改为经私网指向云端新主；按第 5.3 节全停/单版本边界启动两端 App，并验证只有新主可写。
7. 用审计、业务单据、库存/财务控制总额、outbox 与最后 LSN 对账；不得只以健康检查 200 作为恢复完成。
8. 发布事故时间线、实际 RPO/RTO 和待补录清单。

### 9.1 原主重新加入

- 旧主解除 fencing 前必须保持 PostgreSQL 停止；绝不能直接以原时间线启动为主库。
- 先做只读取证备份。
- 若启用了数据校验和或 `wal_log_hints=on`、分叉所需 WAL 完整，并已在演练中验证，可用 `pg_rewind` 从云端新主修复原主；连接密码仍通过 passfile，不写命令行。参考：<https://www.postgresql.org/docs/16/app-pgrewind.html>。
- 任一前提不满足就放弃 rewind，以云端新主重新执行受控 base backup，把原主重建为 standby。重建命令沿用第 4.2 节，但必须改为 `PRIMARY_HOST=pg-standby.imp.internal`、`SLOT_NAME=uten_onprem_replica`、`APPLICATION_NAME=uten_onprem_replica`，并把 `REPLICA_PGDATA/CONFIRM_REPLICA_PGDATA` 改为已核对的本地主机路径；仍然从 passfile 读密码。
- 验证 `pg_is_in_recovery()=true`、回放追平和真实增删改后，才能解除“无热备”状态。

### 9.2 计划回切到本地

回切不是把两边数据“合并”。在维护窗口停止业务写入，确认本地 standby 完全追平，fence 云端写主，提升本地；随后在本地新主用 `prepare-primary.sh` 创建一个新的 `uten_cloud_replica` 槽并应用正向 HBA，切换两端应用连接，再把云端按新时间线重新克隆为 standby。旧的反向槽只有在新拓扑复制和对账全部通过后才可按双人变更单删除。全过程任何时刻只能有一个可写主库，禁止自动 failback。

## 10. 独立备份与 PITR

上线前必须建立并恢复验证：

- 周期性 full/base backup；
- 连续 WAL archive 到与应用附件分离的加密 OSS Bucket；
- Bucket 版本控制、生命周期和防误删权限；
- 至少一份不同账号/故障域的不可变或离线副本；
- 每月随机恢复到隔离 PostgreSQL，执行 Flyway 历史、核心表行数、财务/库存对账与指定时间点恢复；
- 保存每次恢复耗时，形成真实 RTO，而不是估算值。

`pg_basebackup` 成功、热备在线或 OSS 中存在文件，都不等于 PITR 已可用；只有恢复演练通过才算备份有效。

## 11. 隔离 Docker 复制演练

Windows/Docker Desktop 可运行：

```powershell
powershell -ExecutionPolicy Bypass -File deploy/postgres/verify-replication-docker.ps1
```

脚本使用带随机后缀的 `uten-repl-verify-*` 容器、网络和 volume，显式保护并从不操作 `uten-imp-postgres`。它会真实验证：

- 主库准备和副本 base backup；
- 永久槽仍被健康旧副本占用时，使用临时 base-backup 槽完成 staging 并在最终切换后重新接管永久槽；
- `pg_is_in_recovery()`；
- insert、update、delete 回放；
- 断开副本网络时主库继续写和复制槽积压；
- 恢复网络后追平到目标 LSN。

该演练验证的是复制机制，不替代真实 ECS/VPN/TLS/OSS/应用验收。

## 12. 生产放行清单

- [ ] 用户书面接受单主与断网时云端 503，批准 RPO/RTO。
- [ ] 三个 PostgreSQL 身份和密码分离；本地与云端各自真实 `hba_file`、安全组和防火墙均为精确私网来源，两个数据库 DNS 与证书 SAN 通过 TLS `verify-full`。
- [ ] `max_slot_wal_keep_size` 有限且容量、磁盘、槽状态告警已接入。
- [ ] 目标公司/阿里云环境的真实 insert/update/delete、断链积压、追平测试通过（Docker 演练不能代替）。
- [ ] fencing、promote、云端 HBA/反向槽、连接切换、原主 rewind/重建、新槽回切均演练并有双人步骤。
- [ ] 独立 PITR 从零恢复和业务对账通过。
- [ ] 双隧道或专线主/VPN 备切换通过。
- [ ] 两端使用同一组、相互独立的 staging/final Buckets；staging=Off、final=Enabled、`Get/DeleteObjectVersion`、分离的 inventory 恢复身份、精确 CORS/CSP、POST 重放门禁、固定确认版本和“无对账不清理”通过。
- [ ] OSS 大小硬门禁、staging/final、恶意内容扫描、删除 outbox/状态机、pending 配额/孤儿对账清理和版本恢复已在真实 Bucket 闭环；任一未完成仍为 NO-GO。
- [ ] Web 使用 `--no-web-resources-cdn`，原生端固化并限制本地/云端 host；登录页可信恢复入口已补齐；同 issuer/secret，远程授权矩阵通过。
- [ ] Nginx 无占位符且 `nginx -t` 通过，systemd/严格 health/Actuator 404 已启用并接入外部告警。
- [ ] 本地主库 Flyway 与发布版本一致，云端副本已追平 schema；发布/回滚均全停清退会话，两端从未新旧 JAR 混跑。
