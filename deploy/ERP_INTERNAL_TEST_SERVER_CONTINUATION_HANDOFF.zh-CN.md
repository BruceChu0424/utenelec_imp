# 内部 ERP 测试服务器：完整续作交接

<!-- ERP-INTERNAL-TEST-CONTINUATION-HANDOFF-20260814 -->
> **交接快照：2026-08-15（Asia/Shanghai）。** 本文件用于在新任务/新对话中继续完成当前工作。
> 它记录的是仓库候选、已知服务器事实、强制安全边界和剩余验收；不是服务器完成证明。服务器事实主要
> 来自 2026-08-12 的只读核验，恢复内网或企业 VPN 后必须重新采集。本文不得写入真实地址、主机名、
> 登录账号、人员姓名、手机号、密码、令牌、私钥、磁盘序列号或 SSH 指纹。

## 1. 最终目标

把现有物理主机建设成只供公司员工使用的**内部 ERP 测试服务器**，最终应同时具备：

1. 系统 NVMe 上独立的 LVM/ext4 `/data`；
2. PostgreSQL 16 干净测试集群和最小权限 app/migrator 角色；
3. 由签名 migration-only JAR 从空库执行到当前冻结 Flyway head；
4. Spring Boot 后端和 Flutter Web release；
5. Nginx 内部 HTTPS 入口，后端和数据库只监听回环地址；
6. storage、数据库、发布、readiness、入口逐层失败关闭的开机链；
7. 本机备份、容量/健康监控、告警、凌晨 03:00 维护互斥策略；
8. 签名候选的远程 staging、人工 root 激活、断电恢复和回滚证据；
9. 缺盘、错 UUID、错误密钥、数据库漂移、发布中断和重启等真实故障验收。

企业官网、Next.js、官网数据库、官网媒体/CMS、官网 timer **不部署在此主机**。机械盘退出 ERP 的
数据库、附件和唯一备份路径，但在切换阶段不 wipe、不拆阵列，先保留原字节作为短期回退证据。

该主机只允许登记“内部测试”。单块 NVMe 同时承载系统和测试数据，是单点故障；没有独立故障域的
加密 pgBackRest/PITR 副本、真实恢复演练、VPN/MFA、告警送达和正式业务签字前，不得登记“生产 GO”。

## 2. 项目与仓库基线

- 工作区：`D:\Projects\uten_imp`。
- 技术栈：Flutter/Riverpod Web + Spring Boot 3/PostgreSQL 16/Flyway，发布入口由 Nginx/systemd 管理。
- 当前本地分支：`uimp/chore/full-integration-20260815`；交接基线为冻结提交
  `200133e1`（chore(platform): freeze validated full integration candidate），其后叠加
  2026-08-15 全仓审计收口（V257 误改还原、prod 密钥强度门禁、前端响应式/主题规范修复与文档同步）。
- 工作树在冻结提交后只保留当日审计的显式 pathspec 改动；不得 `git reset --hard`、
  不得清空未跟踪文件、不得用旧分支覆盖，也不得把所有变化误称为已提交或已发布。
- 当前远端 `main` 不具备本工作树完整的签名发布/内部测试 commissioning 链。本地旧 tag、旧 JAR、旧
  `build/web`、旧 `dist` 都不是可部署证据。冻结后必须从干净受审提交重新构建、签名、回读和扫描。
- Flyway 文件一经用于数据库即不可修改。禁止 `flyway repair` 掩盖 checksum 漂移；只能用前向修复或
  已演练的恢复。当前 head/迁移数量必须从最终签名 manifest 和 JAR 重新确认，不能只引用旧测试数字。

## 3. 已确认的服务器事实（恢复连接后必须刷新）

截至 2026-08-12 的只读核验：

- 主机使用 UEFI，从约 512 GB NVMe 启动；NVMe 的 LVM PV 中根 LV 约 100 GiB，存在足够空间设计独立
  数据 LV，但最终 free extents 仍须由 root `pvs/vgs/lvs --readonly` 精确证明。
- 当前 `/data` 仍挂在两块约 2 TB 机械盘组成的 md RAID1 上；PostgreSQL 的 `data_directory` 仍位于
  旧 `/data`。
- 两块盘为桌面级 drive-managed SMR，不适合作为本项目的 24x7 权威数据库盘；其中一块有 70 条历史
  UNC。已启动的长测只需在恢复连接后只读归档，结果不改变“机械盘退出 ERP 路径”的决定。
- PostgreSQL 当时 active 且只监听回环地址；ERP、Nginx、updater、watchdog 和员工入口均未启用。
- 旧 repo1 full timer 实际为 02:17；数据库和该 repo 位于同一旧故障域，不算灾备。
- 两次 Phase 1 package-window 失败都留下证据。旧 `uten-imp-phase1-resume.service` 仍可能在重启时触发
  旧 helper；它没有完成 NVMe/新数据库恢复职责。
- 在旧 resume unit 被证据化退役、新恢复链安装并验证以前，禁止计划重启。意外重启后先只读核验，
  不得删 marker、手改 JSON、手工启动 ERP 或数据库。

这些事实不是永久状态。恢复内网/VPN 后，第一件事是重新读取 boot ID、时间、`findmnt`、`lsblk`、
`pvs/vgs/lvs`、`mdstat/mdadm`、systemd units/timers、监听端口、PG cluster、证据目录和备份状态。

## 4. 已完成或已达到的源码阶段成果

以下只表示仓库/离线候选，不表示目标服务器已经执行：

- 已明确采用固定 350 GiB 线性 LV `ubuntu-vg/uten-data`、ext4、UUID 挂载，至少保留 20 GiB VG
  空闲；authority schema 支持 `lvm-linear-nvme` 并绑定 LV/VG/PV/NVMe 身份。
- NVMe storage-only commissioner 曾以固定源码快照完成独立 P0/P1 审计和 WSL/systemd-analyze
  故障测试，覆盖 active pointer、掉电续跑、一次性 gate、旧 md 保留、空 PGDATA 和 late finalizer。
  后续公共 helper 仍在变化，因此上机前必须按最终工作树重新计算摘要并跑完整回归，不能复用旧 SHA 宣称 GO。
- 已新增独立 `internal-test` Spring profile、JVM 早期安全门禁、严格 CIDR 解析、环境变量白名单、
  systemd/Nginx/internal storage 校验和相应测试。`prod/cloud` 的 OSS 门禁没有因内部测试而放宽。
- 已建立签名 release、migration-only JAR、runtime authority、storage boot verifier、DB recovery
  verifier、watchdog、监控、备份和 retention 的候选实现及大量故障注入测试。
- 已建立 host preparer、reviewed manifest builder、DB commissioner、首次 onboarding、恢复
  finalizing 和过期 onboarding reauthorization 的候选代码路径。
- 当前源码冻结候选的 Flyway inventory 为 270 条、head V289，checksum exporter 已同步；该数字只描述
  当前源码字节，目标机仍必须以最终 CI 签名 manifest、双 JAR exact-set 和 live history 重新确认。
- 已完成敏感信息清理方向：当前发布候选不得包含真实拓扑、账号、人员信息或秘密；`dist/` 已按生成
  物处理并忽略。不可变历史迁移如含既有业务值，只能按固定路径+固定 SHA 做窄风险登记，禁止改写已应用迁移。
- 已更新内部测试运行、NVMe commissioning、数据库 onboarding、监控、备份和操作文档框架。

截至本快照，单写者工作树候选已完成本地全量验证：后端 Surefire 401 套 / 1,714 项为 0 failure /
0 error、2 项按门控跳过，Failsafe 双 JAR 打包门禁 2/2 通过；真实公司克隆演练因缺少带外证据而必须
跳过，checksum exporter 默认跳过写文件但已显式执行 1/1 通过。Flutter 729/729，部署链五组 Python 门禁
909 项，V289/270 的 checksum 与双 JAR migration exact-set 一致。受审提交/tag、隔离 CI 签名、OSS
不可变 candidate/readback、真实公司克隆迁移、目标机安装/激活和 HTTPS/UAT/故障/reboot 验收均尚未
形成。目标机仍 **NO-GO**，不得用脚本存在、单项测试或本地构建跨层宣称完成。

## 5. 当前没有完成的工作

### 5.1 形成可提交的最终源码字节

当前工作树已停止并发写入并完成本地候选验证，但仍是大量未提交 changed/untracked 字节，不能上传、
签名或上机。现有 manifest/Nginx authority、稳定 fd/no-follow、exact
schema、operation lock、PID 1 worker、首次 onboarding/reauthorization/first-backup、recovery finalizing、
monitoring 和 retention 都只能登记为**源码候选**。进入受审提交前仍须：

1. 在显式 pathspec 暂存前即时重采 Git 状态、内容摘要、进程和 `index.lock`，确认没有新写入、未合并项、
   生成物、官网目录或 ignored 私密文件混入；禁止 `git add -A .`。
2. 逐提交审阅 cached diff 并复跑高置信秘密扫描；真实秘密、个人账号、内网拓扑和人员信息必须为零命中。
   历史不可变迁移仅允许固定路径+固定 SHA 窄登记，禁止为通过扫描改写已应用 migration。
3. 按 [GitHub 保护/签名 authority 清单](release/GITHUB_SIGNING_AND_PROTECTION_SETUP.zh-CN.md)冻结最终
   Organization/仓库身份和套餐，分别建立人员 Commit/Tag、Release 制品、管理员 SSH 与服务器 Host Key
   authority。当前未配置 Git signing key，禁止用旧 unsigned tag、lightweight tag 或临时自签 key 冒充权威。
4. 在受保护 main/tag 和隔离签名 Environment 中从提交重新执行本地已通过的全部门禁、Docker wheelhouse 构建、
   双 JAR/Web/SBOM/Flyway manifest 生成与签名回读；dirty 本地制品只能作诊断证据。

### 5.2 形成可追溯发布

源码验证全绿仍不等于已发布。必须在干净受审提交上重新生成双 JAR、Flutter Web、CycloneDX SBOM、
Flyway manifest 和签名 release；按
[GitHub 保护/签名 authority 清单](release/GITHUB_SIGNING_AND_PROTECTION_SETUP.zh-CN.md)建立受保护分支/tag、
required checks、隔离签名 Environment 与 allowed-signers，并补齐当前工作流尚未自动执行的 tag object
signature 人工复核证据，
再以 create-only/versioning/WORM 策略上传 OSS 并逐对象回读。旧 `server/target`、`build/web`、`dist`、旧
摘要和 dirty build 全部作废。只有 commit、CI run/artifact、签名 key、OSS object/version/readback 形成同一
lineage，才可登记“可暂存”；此前不得把本地候选复制到服务器。

### 5.3 取得目标机当前事实与写入授权

首次连接前必须完整执行
[目标服务器带外身份与访问 authority 清单](target-host-oob-authority.zh-CN.md)，由受控 CMDB/带外交接形成
H01–H12：当前环境、IP/FQDN/端口/账号/时间/负责人、完整 SSH Host Key 与轮换记录、批准 VPN/VLAN/源路由、
两把独立管理员公钥、泄露口令轮换和可用物理/BMC 控制台。审核端从带外完整公钥预制项目专用
`known_hosts`，所有连接固定 `StrictHostKeyChecking=yes`；历史 `known_hosts`、`ssh-keyscan` 或“网络可达”
都不能建立信任。H01–H12 通过后也只做第 6 节第 1 步的只读刷新，向操作员展示精确计划、风险和回退并取得
确认；在此之前不得连接，更不得提供或执行针对该目标的写入、enable/start、数据库、激活或 reboot 命令。

### 5.4 目标机与业务验收

完成签名 candidate 并取得写入授权后，仍须逐事务获得 storage、host preparation、DB onboarding、首份
本机 full/WAL/check、首次 activation、recovery finalizing、monitoring/retention 和 boot receipt。旧
`uten-imp-phase1-resume.service` 必须在任何计划 reboot 前证据化退役，证明不会再调用旧 helper。最后还须
完成真实 HTTPS 登录、权限负向矩阵、关键业务 UAT、容量/告警送达、故障注入和单独批准的 reboot；任何一项
缺失都保持目标机 NO-GO。

## 6. 恢复内网后的固定执行顺序

任何一步没有 durable terminal receipt，后一步不得开始：

1. **只读刷新**：核验主机身份、boot ID、时间、NVMe/LVM/md、fstab、监听、PG、systemd、证据目录、
   备份和磁盘长测结果；不得写入。
2. **退役旧恢复链**：用受审事务封存旧 Phase 证据，disable 旧 resume unit，证明不会在重启时调用旧 helper。
3. **NVMe assess/plan**：重新生成 plan，核 350 GiB 后的精确 VG reserve、NVMe 健康、所有 writer 和回退。
4. **NVMe apply/late finalize**：停止相关服务，创建 LV/ext4、切换 fstab、发布 v3 authority；旧 md 不擦除。
   成功边界仍是 storage-only：空 PGDATA、数据库/ERP/Nginx/备份/入口关闭。
5. **受审 host preparation**：使用独立 builder authority、reviewed manifest、TLS/DNS/CIDR/preimage，安装
   internal runtime；终端仍必须 `entryEnabled=false`。
6. **签名 stage/inspect**：由无特权 updater 从 OSS 只读下载、验签、inspect；自动 staging timer 仍 disabled。
7. **DB assess/apply/resume**：通过固定 systemd worker 初始化空集群、角色、V1 到冻结 head、live ACL；
   生成 onboarding/complete/committed pointer，入口仍关闭。
8. **本机 backup**：为新 system identifier 建首份 full/WAL 验证；在真实 restore 前只算快速恢复层。
9. **首次 activation**：清退会话，消费 onboarding 或受控 reauthorization，原子切换 release，依次验证
   PostgreSQL、ERP、静态 Web、Nginx 和 watchdog；任何失败保持 fail-closed。
10. **真实故障与 reboot**：缺卷、错 UUID、坏密钥、ACL 漂移、listener、SIGKILL、finalizer、掉电恢复、
    updater身份、systemd sandbox 全部通过后，单独批准 reboot 并验证 `/data -> PG -> ERP -> Nginx`。
11. **内部测试验收**：真实 HTTPS 登录、岗位权限负向矩阵、关键业务流程、容量告警和恢复证据通过后，
    才能登记“内部测试 GO”。

## 7. 离开内网期间可以和不可以完成的工作

不在公司内网时仍可完整完成：源码修复、文档、测试、干净构建、SBOM、签名候选、敏感扫描、CI、
OSS 暂存设计和目标机命令/回退清单。前提是所有所需依赖和代码可访问。

不在内网且没有已验收 VPN/零信任/SSH 跳板时，**不能**完成：目标机只读刷新、NVMe 切换、DB init、
实际部署、内部 DNS/TLS 验证、开机自启、真实故障注入、HTTPS 登录、UAT 和“服务器已可用”的最终证明。
不得为赶时间临时公网暴露 SSH、PostgreSQL、8080/8081 或 ERP；不得把路由器端口映射当远程更新方案。

如果已经存在受控企业 VPN/零信任通道，可在外网继续目标机工作，但仍须重新验证目标主机身份、SSH
host key、最小权限、物理控制台回退和变更窗口。没有这些证据时，只继续源码和发布候选，不写服务器。

## 8. 强制规则与禁止事项

### 8.1 文件与 Git

- 先 `git status --short --branch`；保留并行修改，不 reset、不 checkout 覆盖、不批量删除。
- 修改使用可审查 patch；生成物和格式化批量改写与业务源码分开。
- 不把脏工作树直接复制到服务器，不从开发目录以 root 执行 Python/Bash。
- 只有固定 root-owned、单硬链接、不可组/全局写、摘要已带外核验的 snapshot 才可成为 root 工具来源。
- “本地修改”“本地测试通过”“已提交”“已推送”“已合并”“已签名”“已暂存”“已部署”“已验收”
  必须逐层区分，禁止用一个状态代替下一个状态。

### 8.2 数据库与数据

- 当前数据虽可丢弃，也必须通过事务化清单、preimage、receipt 和回退处理；禁止随手删 PGDATA/附件/备份。
- 不复制运行中的 PGDATA；选择干净 initdb + 签名迁移。机械盘旧数据先保留原字节。
- 不改已应用 Flyway migration，不运行 `flyway repair` 掩盖漂移，不用旧 JAR 回滚包含新 migration 的库。
- 密码/密钥只进入 root-only 文件或受控 fd/systemd credential；不进入 CLI、源码、日志、receipt、聊天。
- 数据库、备份、迁移、apt/dpkg、SMART、文件系统检查、发布和 reboot 使用同一维护互斥策略，不并发。

### 8.3 网络与入口

- PostgreSQL 5432、Spring 8080 和静态探针 8081 只允许回环；员工仅经 Nginx HTTPS。
- 只允许精确内部 DNS 和精确办公室/VPN 私网子网；拒绝公网 CIDR、宽私网根、host-bit、非 canonical、
  重复/空项和未知 IPv6。远程办公使用企业 VPN/零信任 + MFA。
- 官网 ingest、附件上传、Swagger、短信、外部 API 和未验收自动更新保持关闭；员工查询/管理 API 不应被
  Nginx 误拦。路由合同必须从真实 Controller 动态校验。
- 80/443/8080/8081 的 TCP/UDP listener 都要查；额外 include、隐式/default listen、未知 directive、
  单行 server block 和可写 include 全部 fail-closed。

### 8.4 证据、恢复与运维

- JSON 证据 append-only；不覆盖、不删除、不手工补字段。碰撞、未知文件、schema/metadata 漂移即停。
- 每个 destructive/mutation 动作前先写并 fsync authority；每个终态写 receipt，再清 pointer/marker。
- SIGKILL/掉电恢复只能采用精确 lineage 和 live 重验，不得因为“看起来已经完成”跳过。
- `nofail` 只允许根系统在数据 LV 挂载失败时进入维护；PostgreSQL 必须在写字节前被 storage verifier 阻断。
- 03:00 是未来维护最早开始时间，不是自动 reboot。02:17 full 若仍运行，维护跳过或顺延，不 kill backup。
- 自动 updater 只做 staging，默认 timer disabled；root activation 必须人工维护窗、签名校验、备份和会话清退。

## 9. 服务器最终落位清单

新任务必须通过源码常量、安装器、systemd effective properties 和目标机实况逐项复查下面的清单；路径表是
目标结构，不是“已经安装”的声明。发现实际代码与表不一致时，先判断哪一方是受审权威，再同步 producer、
consumer、测试和文档，不能只改文档绕过校验。

### 9.1 存储与数据

- `/dev/ubuntu-vg/uten-data`：固定 350 GiB linear LV；不得 thin/stripe/snapshot。
- `/data`：ext4、UUID 挂载、`rw,nodev,nosuid,noexec`，并由 storage verifier 防止未挂载时写入根盘。
- `/data/postgresql/16/main`：新 PostgreSQL 16 PGDATA；initdb 前为空且不跨文件系统/不为 symlink。
- `/data/uten-imp/attachments/{staging,final}`：内部测试附件目录；上传功能未验收前只保留读取合同。
- `/data/backups/pgbackrest` 或最终受审 repo1 路径：新 system identifier 的本机恢复层；不得把旧 repo
  或同盘副本称为异地灾备。
- `/etc/fstab`、LVM metadata、NVMe identity 和旧 md preimage：全部在证据事务中保存；旧 md 不 wipe。

### 9.2 配置、信任与秘密

- `/etc/uten-imp/storage-authority.json`：schema v3 NVMe/LVM authority，root-controlled。
- `/etc/uten-imp/server.env`：internal-test 运行环境与 app secret，只允许受控原子替换。
- `/etc/uten-imp-migrator/migrator.env`：只供一次性 migrator，应用 unit 不可读取。
- `/etc/uten-imp-postgres/`：app/migrator 密码及 PostgreSQL 相关 root-only secret。
- `/etc/uten-imp/tls/`：内部 DNS 证书和私钥；runtime contract 绑定路径、摘要、SAN、有效期和 key match。
- `/etc/uten-imp-release-trust/release-allowed-signers` 与
  `/etc/uten-imp-updater/release-allowed-signers`：两份受审且相同的签名信任根，禁止首次观察即信任。
- `/etc/uten-imp-updater/oss-pull.env`：只读候选下载所需的受控配置/短期凭据；不进入应用环境或日志。

### 9.3 应用和更新器

- `/opt/uten-imp/releases/<签名版本>/`：不可变 JAR、migrator JAR、Flutter Web、SBOM、manifest/校验信息。
- `/opt/uten-imp/current`：只通过同文件系统原子 symlink 切换到一个已验证版本；禁止原位覆盖。
- `/opt/uten-imp/updater/`：固定 updater、release guard、OSS helper、validator、requirements lock、
  wheelhouse supply-chain verifier 和 root 不可写的离线 venv。
- `/usr/local/sbin/uten-imp-activate`、`uten-imp-recover`：固定 root wrapper；不接受散装脚本或开发目录。
- `/usr/local/sbin/uten-imp-existing-test-host-db-commissioner`：只允许 dispatcher 命令；隐藏 worker 只由 PID 1。
- `/usr/local/sbin/uten-imp-validate-*`：环境、storage、migrator 等前置校验器。
- `/usr/local/libexec/uten-imp-release/`：runtime/storage/DB/recovery/migration verifiers 和 release guard。
- `/usr/local/libexec/uten-imp/`：readiness、watchdog、entry watchdog 等固定 helper。

### 9.4 systemd、Nginx 与证据

- PostgreSQL meta/instance unit 和唯一正式 storage drop-in；临时 commissioning guard 必须由 DB 事务
  证据化接管，不能与正式 gate 永久共存。
- `uten-imp.service`、`uten-imp-migrate.service`、`nginx.service` drop-in、两个 watchdog service/timer、
  updater service/timer、DB commissioner worker、storage/recovery verifier、backup/monitoring/retention units。
- `/etc/nginx/sites-available/uten-imp-internal-test.conf` 及唯一受审 enabled link；旧 Phase4 include 必须
  事务化归档，不能形成双入口。
- `/var/lib/uten-imp-nvme-commissioning/`：storage append-only evidence 与 active pointer。
- `/var/lib/uten-imp-internal-test-host-preparation/`：主机准备 evidence、mutation authority 和 terminal receipt。
- `/var/lib/uten-imp-internal-test-commissioning/`：DB pre-active/active/worker request/terminal evidence。
- `/var/lib/uten-imp-release/`：operation lock、active/runtime authority、onboarding、reauthorization、
  activation/recovery/finalizing/failure markers 和 append-only evidence。

所有安装结果必须再用 `systemctl cat/show`、`systemd-analyze verify`、`nginx -T`、文件 metadata/SHA、
`findmnt`、live listeners 和真实进程命令行核对；“文件存在”不能代替 effective runtime contract。

### 9.5 以后代码更新的完整闭环

最终稳定链应为：

```text
受保护 main/tag
  -> CI 全量测试与干净构建
  -> 生成双 JAR、Flutter Web、SBOM、Flyway manifest
  -> 隔离签名并发布不可变 OSS candidate
  -> 服务器无特权 updater 定时发现、下载、验签、配额/保留检查
  -> 只写 staging 并告警“有新候选”
  -> 管理员 inspect、备份、会话清退和变更确认
  -> root 原子 activate
  -> DB/release/runtime/Nginx/watchdog 探针
  -> 成功写 active/runtime authority；失败保持入口关闭并走受控 recover
```

“自动下载”可以在完整验收后启用 updater timer，但它只允许下载、验签和 staging。数据库 migration、
`current` 切换、服务启停和入口开放不得无人审批自动执行。这样外出时服务器能自动取得新候选并通知，
但不会因为一次错误提交、网络劫持、坏 migration 或断电自动破坏正在运行的后端。

自动 staging 启用前还必须完成：OSS read-only 最小权限、签名 key 轮换、candidate create-only/versioning/WORM
策略、最大下载/解压/保留容量、并发锁、旧候选清理、断网/半包/坏签名/磁盘满/掉电回归、告警真实送达。
正式运行后应持续监控 PostgreSQL、ERP liveness/readiness、Nginx/static version、systemd failed、磁盘/inode、
备份新鲜度/WAL、证书到期和 updater staging 失败；不能只依赖 `Restart=always`。

## 10. 完成定义

只有以下证据同时存在，目标才算完成：

- GitHub/签名 authority 与目标机 H01–H12 带外材料分别验收，最终源码冻结、完整测试和敏感扫描全绿，
  受保护提交/tag/签名/OSS readback 可追溯；
- 服务器上 v3 NVMe authority、storage-only complete/late receipt 和旧 md 保留证据齐全；
- 新 PostgreSQL system identifier、Flyway exact history、角色/ACL、HBA、secret auth 和 DB terminal receipt 齐全；
- 新 release 的 active/runtime authority、HTTPS/版本/readiness/watchdog 探针和 boot enablement 齐全；
- 首份备份和恢复验证、容量/健康告警、维护互斥与真实 reboot/failure injection 齐全；
- 员工真实登录、岗位权限负向矩阵和关键业务 UAT 通过；
- 官网未部署、机械盘不在 ERP 权威路径、任何内部服务未暴露公网。

即便上述内部测试条件完成，独立故障域 PITR/VPN/MFA/业务正式迁移和生产审批未完成时，生产仍 NO-GO。

## 11. 新任务接手指令

新任务应先完整阅读：

1. 本文件；
2. `deploy/current-test-server-status.zh-CN.md`；
3. `deploy/setup/EXISTING_TEST_HOST_NVME_COMMISSIONING.zh-CN.md`；
4. `deploy/setup/EXISTING_TEST_HOST_INTERNAL_TEST_ONBOARDING.zh-CN.md`；
5. `deploy/internal-test-runtime.zh-CN.md`；
6. `deploy/release/README.md`、`deploy/release/GITHUB_SIGNING_AND_PROTECTION_SETUP.zh-CN.md`；
7. `deploy/target-host-oob-authority.zh-CN.md`、`deploy/operator-guide.zh-CN.md`；
8. 与当前修改相关的源码和测试，以及 `git status --short --branch`。

接手后必须先做一次**独立完整审计**，不能假定本交接列出了全部缺口：从 Git/dirty worktree、CI、签名
payload、安装 producer/consumer、systemd/Nginx effective contract、数据库/Flyway、备份/监控、断电恢复、
远程更新到目标机状态逐层检查。然后合并审计新发现与第 5 节清单，按风险从 P0/P1 到 P2 收口。

不要重做已验证的存储设计，也不要直接上服务器。先锁当前文件摘要，重跑未冻结桥接链的测试，关闭第 5 节
及独立审计发现的剩余门禁，形成干净签名候选；恢复内网后再按第 6 节执行目标机事务。任何时候都要把
“源码候选”和“服务器实际状态”分开报告，直到第 10 节全部有目标机证据才可结束任务。
