# 云端部署 Runbook（阿里云 ECS：授权外网访问 + 只读副本）

本文件是「本地主库 + 阿里云端」双服务器方案的**开箱即用**操作手册。代码、迁移、脚本已全部就绪；
**你只需按本文件开通资源、在 `server-cloud.env` 里填密钥**，即可启动。**缺必填 key，cloud profile 启动即 fail-fast 报错**（不会静默连错库）。

## 架构与不变量

```
内网员工 ──LAN──> [本地服务器: App + PG 主库(唯一可写)] ──IPsec VPN / 高速通道──┐
                                                                                ▼ 流复制 + 复制槽 cloud_rep
授权外网员工 ──HTTPS──> [阿里云 ECS: App(cloud) + PG 副本(只读)]  ──RAM 角色──> [阿里云 OSS]
```

- **永远只有本地主库可写**（零双主冲突 / 零丢账）。云端 App 经 `CloudRoutingDataSource` 路由：
  主库健康 → 全走主库（实时、一致，与内网同库）；主库不可达（断网）→ **云端对居家员工整体不可用**：经认证的业务请求一律 503（认证需读主库账号状态；**故意不从陈旧副本鉴权**，保证 `remote_access` 撤销即时生效、无安全窗口），写请求同样 503（不在云端缓存写，故永不存在「两边写入要合并」）。
- 断网恢复后，副本经复制槽 `cloud_rep` 从 WAL 断点自动续传，**无需任何自写同步逻辑**。副本的角色是**灾备热备**（可 `pg_promote()` 提升），不对外提供读流量。详见 ADR-031。
- **只有 `remote_access=TRUE` 的账号能连云端**（`RemoteAccessGuardFilter`，`site=cloud` 生效）；开关即时失效旧 token。
- 文件存阿里云 OSS：云端 ECS 用 **RAM 角色免密钥**；本地服务器用 AK/SK。报销等附件走预签名 URL 直传。

## 前置准备

1. 阿里云 ECS（同 region 建议 2C4G 起，与 OSS 同 region 走内网省流量），分配**弹性公网 IP + 域名 + TLS 证书**。
2. 公司本地 ↔ 云端的安全通道，二选一：
   - **起步（便宜加密）**：IPsec 站点到站点 VPN（阿里云 VPN 网关 ~300–600 元/月，或两端自建 strongSwan）。
   - **进阶（低延迟）**：高速通道专线（物理专线，内网直连不经公网）；生产可「专线主 + VPN 备」。
   - 目标：云端 ECS 能用内网 IP（如 `10.8.0.1`）连到公司本地 PG `5432`。
3. OSS Bucket（同 region）+ 一个 **ECS 实例 RAM 角色**（受信实体=ECS，策略给 `AliyunOSSFullAccess` 或更细粒度）。

## 步骤

### ① 云端装 PostgreSQL 16 + 搭只读副本

在云端 ECS：
```bash
apt install -y postgresql-16
# 用本仓库脚本（在云端跑，连主库克隆）
PRIMARY_HOST=10.8.0.1 REPL_PASSWORD='强随机密码' ./deploy/postgres/setup-replication.sh
```
主库侧：把 `deploy/postgres/primary.conf.example` 合并进 `postgresql.conf`（重启），`pg_hba-replication.conf.example` 的网段改成 VPN 网段。
验证主库：`SELECT application_name, state FROM pg_stat_replication;` → `state=streaming`。

### ② 给云端 ECS 挂 RAM 角色（OSS 免密钥）
阿里云控制台 → ECS 实例 → 授予实例 RAM 角色（第 3 步准备的那个）。挂上后，`UTEN_OSS_USE_INSTANCE_ROLE=true` 即免 AccessKey。

### ③ 填 `server-cloud.env`（你的密钥只填这里）
复制为 `/etc/uten-imp/server-cloud.env`（仅服务账号可读），填：
```env
UTEN_PROFILE=cloud
# --- 双数据源（缺任一 → 启动 fail-fast）---
UTEN_DB_PRIMARY_URL=jdbc:postgresql://10.8.0.1:5432/uten_imp   # 主库(本地,经VPN)
UTEN_DB_REPLICA_URL=jdbc:postgresql://127.0.0.1:5432/uten_imp  # 副本(云端本地)
UTEN_DB_USER=uten
UTEN_DB_PASSWORD=__主库密码__
# --- 必填安全三件套（与本地一致）---
UTEN_JWT_SECRET=__与本地一致或更强的强随机串__
UTEN_PGP_MASTER_KEY=__与本地一致(解同一份密文)__
UTEN_HMAC_KEY=__与本地一致__
UTEN_JWT_ISSUER=uten-imp-cloud
UTEN_CORS_ORIGINS=https://__CLOUD_DOMAIN__
UTEN_REQUIRE_HTTPS=true
# --- OSS（云端用 RAM 角色，免 AK/SK）---
UTEN_STORAGE_PROVIDER=oss
UTEN_OSS_USE_INSTANCE_ROLE=true
UTEN_OSS_ROLE_NAME=__ECS_RAM角色名__
UTEN_OSS_ENDPOINT=https://oss-__region__.aliyuncs.com
UTEN_OSS_BUCKET=__bucket名__
```
> ⚠️ `UTEN_DB_PRIMARY_URL` / `UTEN_DB_REPLICA_URL` / `UTEN_JWT_SECRET` / `UTEN_PGP_MASTER_KEY` / `UTEN_HMAC_KEY` 任一为空，cloud profile **启动即报错不运行**（`CloudDataSourceConfig` + `application*.yml` fail-fast）。

### ④ 发布 + 启动
```bash
# 发布 jar（与本地同一份产物；profile 由 env 决定）
/opt/uten-imp/current/server/uten-imp-server.jar
cp deploy/cloud/uten-imp-cloud.service.example /etc/systemd/system/uten-imp-cloud.service
cp deploy/cloud/nginx-cloud.conf.example /etc/nginx/conf.d/uten-imp-cloud.conf  # 改 __CLOUD_DOMAIN__ 与证书路径
systemctl daemon-reload && systemctl enable --now uten-imp-cloud
nginx -t && systemctl reload nginx
```
健康检查：`curl http://127.0.0.1:8080/actuator/health`。

### ⑤ 授权可外网账号
用超管（在本地或云端）调：
```bash
curl -X PUT https://__CLOUD_DOMAIN__/api/admin/users/<userId>/remote-access \
  -H 'Authorization: Bearer <超管token>' -H 'Content-Type: application/json' \
  -d '{"remoteAccess":true}'
```
开关即生效：该用户旧 token 立刻失效（`auth_version` bump），重新登录后即可外网使用。无 `remote_access` 的账号即使知道云端地址也被 403。

### ⑥ 客户端：自动识别 + 云端地址

App（`server_selection.dart`）默认**自动模式**：启动与每 60s 探测本地后端 `/actuator/health`，**在公司内网→自动用本地，在外网→用云端**。设置页 →「服务器」：

- 「云端地址」填 `https://__CLOUD_DOMAIN__/api`；
- 模式选「自动」（默认）/「仅本地」/「仅云端」（后两者排障用）；
- 仅被授权 `remote_access` 的账号可在云端登录（门禁在后端 `RemoteAccessGuardFilter`）。

> **无缝自动切换前提**：本地与云端须用**相同的 `UTEN_JWT_ISSUER` 与 `UTEN_JWT_SECRET`**（二者共享同一份数据库副本，同一 token 可在两端校验通过）；否则跨本地↔云端切换会要求重新登录。

## 运维与故障演练

- **复制延迟**：主库 `SELECT * FROM pg_replication_slots;` 看 `restart_lsn`；`pg_stat_replication.replay_lsn`。
- **模拟断网**：在云端阻断到主库的 VPN（或 iptables drop `10.8.0.1:5432`）。10 秒内 `PrimaryHealthIndicator` 翻 DOWN → 云端对居家员工不可用：经认证的 GET/POST/PUT/DELETE 一律返 503（认证需主库，不从陈旧副本鉴权）。**公司内员工不受影响**（局域网直连主库）。恢复 VPN → 副本经复制槽自动追平 → 云端恢复可用。详见 ADR-031 §三。
- **灾备（本地主库彻底毁）**：在云端副本 `pg_promote()` 提升为新主库（注意：此后须重建原方向复制，且期间内网与外网都指向云端）。属灾备场景，非日常。

## 本地预演（不开通阿里云也能验）
用两个本地 PG 容器跑 `setup-replication.sh` 验「主写副本见、断网主照写、恢复续传、云端 App 对认证请求 503」。路由逻辑已有单测 `CloudRoutingDataSourceTest`（4/4 绿）覆盖。
