# 内部 ERP 测试服务器：当前状态与执行基线

<!-- CURRENT-ERP-TEST-SERVER-SCOPE-20260812 -->
> **状态日期：2026-08-15（Asia/Shanghai）。** 本文件是当前物理服务器范围、存储决策、执行顺序和
> 暂停条件的权威摘要。历史 Phase 1、RAID/SMART 报告和旧交接只保留为证据；与本文冲突时不得继续
> 照旧执行。本文不记录真实 IP、密码、私钥或磁盘序列号。
> 跨任务继续实现、测试和目标机验收时，还必须阅读
> [完整续作交接](ERP_INTERNAL_TEST_SERVER_CONTINUATION_HANDOFF.zh-CN.md)。

## 1. 最终范围

当前主机只建设新的**内部 ERP 测试环境**：

1. PostgreSQL 16 干净测试库；
2. Spring Boot ERP 后端；
3. Flutter ERP Web，由同机 Nginx 提供 HTTPS 静态页面和 `/api` 反向代理。

<!-- WEBSITE-NOT-ON-ERP-HOST -->
企业官网、Next.js、官网数据库、媒体、CMS 和官网 timer 本轮全部不部署；以后放到独立云服务器。

现有数据库、附件和备份均按测试数据处理，未来正式数据另行迁移。这个决定允许受控重建，但不允许
随手删目录：存储事务必须先保存清单、配置 preimage 和回退证据，精确停服后才切换。

## 2. 存储决策（取代旧 RAID 验收路线）

<!-- INTERNAL-TEST-NVME-DATA-DECISION-20260812 -->
- ERP 的新 `/data` 使用系统 NVMe 现有 LVM VG 中的固定 **350 GiB 线性 LV**
  `ubuntu-vg/uten-data`，ext4；根文件系统不扩容，并至少保留 20 GiB VG 空闲作为运维余量。
- `/data` 通过文件系统 UUID 挂载，要求 `rw,nodev,nosuid,noexec`。主机可在数据卷故障时进入远程维护，
  但 PostgreSQL 在写入任何字节前必须由固定 root verifier 精确核验 UUID、LVM/PV/NVMe 拓扑、容量、
  mount options 和 `data_directory=/data/postgresql/16/main`；验证失败时数据库、ERP 和入口保持关闭。
- 两块机械盘是桌面级 SMR 盘，其中一块存在历史 UNC。它们**退出 ERP 数据、运行时附件和唯一备份路径**，
  不再启动另一块盘长测，也不再把 RAID `check` 当作本轮部署前置。
- 已经启动的 `/dev/sdb` 长测允许自然结束并只读归档结果；无论结果怎样，都不会把该盘重新登记为 ERP
  权威盘。旧 md 阵列本轮不 wipe、不拆阵列、不 `lvremove`，只在切换后保持未挂载，作为短期回退证据。
- 单块 NVMe 同时承载系统和测试数据，仍是单点故障，只能登记“内部测试”。正式数据进入前必须增加
  独立故障域的加密 pgBackRest/PITR 副本并完成真实恢复演练，推荐再增加适合服务器的第二块 SSD。

## 3. 最近一次目标机快照与当前证据边界

以下目标机事实只来自 2026-08-12 的只读快照，尚未通过当前 CMDB 身份、带外 SSH host key、受控网络路径
和新的只读会话刷新，因此不得当作 2026-08-15 的实时状态，也不得据此执行写入命令：

- 当时 ERP/Nginx/旧 updater/旧 watchdog 均关闭，员工入口未开放；PostgreSQL 只监听回环地址。
- 当时 `/data` 仍是旧 md RAID，PostgreSQL 仍在旧路径运行；NVMe commissioner 尚未在服务器执行。
- 当时旧 repo1 full timer 为每天 02:17，数据库和仓库位于同一旧阵列，不算灾备。
- 两次 Phase 1 package-window 失败均失败关闭并保留证据；旧
  `uten-imp-phase1-resume.service` 仍可能在重启时调用旧 helper。完成当前身份刷新、证据化退役并安装新
  NVMe 恢复链前，**禁止计划重启**；意外掉电后不得删除 marker 或手工启动 ERP/PostgreSQL。

仓库侧已形成后端、Flutter Web、签名发布、NVMe/DB onboarding、首次备份、监控和 retention 的源码候选。
当前未提交工作树的 Flyway inventory 为 **270 条、head V289**；最终后端 `clean verify` 的 Surefire
401 套 / 1,714 项为 0 failure / 0 error、2 项按门控跳过，Failsafe 双 JAR 打包门禁 2/2 通过；其中真实公司
克隆演练因缺少带外身份、备份摘要与批准引用而必须跳过，checksum exporter 默认拒绝写文件但已另行显式
执行 1/1 通过。Flutter 729 项和部署链 909 项也均为 0 failure / 0 error，checksum 与双 JAR migration
exact-set 已核对。这仍只是本地源码候选事实；WSL 缺少 Docker，wheelhouse 实际容器重建也必须留给受保护
CI。目标机只接受同一 CI 签名 manifest/JAR 声明的 exact inventory。任何旧测试计数、旧 Flyway head、
dirty 构建目录或旧摘要都不是发布权威。

| 证据层 | 当前状态 |
|---|---|
| 源码候选 | 本地全量验证通过；仍未提交、未签名 |
| 受审提交/tag | 未形成 |
| GitHub/签名 authority | 本机人员签名配置为空；CLI token 无效；远端保护/Environment/plan 无当前读回，按 NO-GO |
| 目标机 OOB authority | CMDB 元组、Host Key、双管理员密钥、批准网络、控制台和口令轮换无当前完整包 |
| CI 签名发布 | 未形成 |
| OSS 不可变候选与回读 | 未形成 |
| 目标机安装/激活 | 未执行、未验证 |
| HTTPS/UAT/故障/reboot 验收 | 未执行，内部测试与生产均 NO-GO |

## 4. 固定执行顺序

所有高风险动作分成独立、可恢复的事务；前一事务没有 durable complete receipt 时，后一事务不得开始。

1. **只读评估**：以 root 读取准确的 `pvs/vgs/lvs`、NVMe 健康、当前 fstab、服务和旧 Phase 证据；
   精确证明 350 GiB LV 建立后仍满足 VG 余量。
2. **NVMe 存储事务**：停备份/入口/PostgreSQL，保存 preimage；创建并实写验证新 LV/ext4；原子切换
   fstab；发布 schema v3 `lvm-linear-nvme` authority；只创建空 PGDATA；旧 md 保持原字节未挂载。
3. **干净数据库事务**：保存旧 cluster 配置；在新空 PGDATA 初始化 PostgreSQL 16；生成 root-only 独立
   app/migrator 密码；建立最小权限角色和空 `uten_imp`；只由同一签名候选的 migration-only JAR 执行到
   该候选声明的冻结 head，再逐行核对其完整签名 Flyway inventory。禁止 `flyway repair`，禁止复制运行中的旧 PGDATA。
4. **本机恢复层**：在新卷建立加密 repo1、取得首个 full 和 WAL 验证；本机备份只算快速恢复层。
   repo2、WORM、异地告警没有真实 provider 前保持 disabled，不能伪造“灾备完成”。
5. **应用事务**：安装冻结的后端 JAR、migration-only JAR、Flutter Web、SBOM 和 manifest；使用唯一
   `internal-test` profile，附件上传、官网 ingest、Swagger、短信、外部 API 和自动数据库迁移全部关闭。
6. **内部入口**：先使用可解析的内部 DNS 名称和受终端信任的测试 CA 证书；后端只监听回环地址，
   Nginx 只放行精确办公室/VPN CIDR。页面和员工文档不显示裸 IP。
7. **开机链**：只有 storage、数据库、release/Flyway、readiness 和 Nginx 全部通过后，才 enable
   PostgreSQL、ERP、Nginx 和两个 watchdog。migration、失败恢复、官网以及未验收的自动 staging timer
   不进入普通开机链。
8. **故障与重启验收**：先验证缺卷、错 UUID、空 PGDATA、错误密钥、错误 profile、数据库未就绪和后端
   失败均关闭入口；再单独批准一次真实 reboot，证明 `/data → PostgreSQL → ERP → Nginx` 自动恢复。

## 5. 维护、备份和自检时间

<!-- FUTURE-MAINTENANCE-WINDOW-0300-ASIA-SHANGHAI -->
- 当前无人使用且全是测试数据，可随时安排停机；不必等到 03:00。
- 未来使用后，每天 **03:00（Asia/Shanghai）** 是维护/自检最早开始时间，不是每日自动重启授权。
<!-- OBSERVED-REPO1-FULL-0217 -->
<!-- MAINTENANCE-SKIPS-ACTIVE-BACKUP -->
- full backup 继续安排在 02:17；03:00 任务必须先取得同一数据库维护锁。备份/expire 仍在运行就跳过或
  顺延维护，禁止为了赶时间 stop/kill pgBackRest。
<!-- HOST-MAINTENANCE-JOBS-MUTUALLY-EXCLUSIVE -->
- backup/expire、SMART、自检、文件系统检查、apt/dpkg、发布迁移和 reboot 不得重叠。自动更新不得自行
  重启；需要重启的更新必须在证据、告警和回退均通过后另行批准。

## 6. 命名、远程访问和人员

- 临时员工入口使用已验收的内部 DNS 名称，不把地址写进 Flutter 制品。公司域名确定后再受控切换。
- 当前先允许公司内网。未来外出办公统一通过企业 VPN/零信任接入并启用 MFA；不得把 PostgreSQL、
  Spring 8080、SSH 管理面或内部 ERP 直接暴露公网。VPN provider/账号未验收前不虚构完成状态。
- 上架前由项目负责人终验；财务、仓库等岗位测试负责人只在受控人事授权清单登记，公开仓库不记录姓名，也不根据
  “某某荣”口头片段猜写。

## 7. GO / NO-GO

- 目前允许继续源码收口、文档和外部 authority 配置。目标身份、Host Key、网络路径和控制台材料未齐时，
  连目标机只读连接都不授权；更不允许 NVMe、数据库或任何其他 commissioning。实际入口仍 **NO-GO**。
- NVMe authority、与最终签名 inventory 完全一致的干净数据库、首个可恢复 backup、内部 DNS/TLS、
  开机恢复和多岗位测试 UAT
  全部通过后，才可登记“内部测试 GO”。
- 独立故障域 PITR、真实告警送达、VPN/MFA、受保护远程签名发布、正式数据迁移和业务签字完成前，
  “生产 GO”始终禁止。
- 企业官网不属于本轮 ERP 主机的 GO 判定，继续延期到独立云服务器。

## 8. 2026-08-15 续作状态

- 五路并行深审（安全/业务联动/前端/部署更新链/文档对齐）已在冻结候选之上完成，无 P0/P1；
  修复项（V257 误改还原、prod 密钥强度门禁、4 个固定宽度 Dialog 自适应、业务文件裸色收敛、
  3 处过时文档、analyze 排除 `_scratch`）以显式 pathspec 提交于
  `uimp/chore/full-integration-20260815`，明细见
  [2026-08-15 全仓综合审计与冻结候选收口报告](../docs/99-项目治理/2026-08-15-全仓综合审计与冻结候选收口报告.md)。
  这些只是源码候选层修复，不改变本节任何未完成门禁的结论。
- NVMe storage-only commissioner、internal-test 主机准备、干净数据库 commissioner、首次 onboarding、
  过期再授权、一次性首备份 gate、Nginx recovery finalizing、远程 updater、监控和 retention 已有源码候选；
  目标服务器均未据此执行。
- 当前剩余重点是把单写者本地候选按显式 pathspec 形成受审签名提交/tag，在受保护 main/tag 与隔离环境
  重跑全套门禁、Docker wheelhouse 和干净构建，再完成 OSS 不可变上传/回读。上次远端审计显示 GitHub
  `main` 未受保护且 production release Environment 不存在；2026-08-15 本机 `gh` token 无效，无法重新读回，
  人员 Git signing 配置仍为空。同日凌晨网页实测：仓库已在组织 `UTEN-ELECTRICAL` 下（私有），
  `protect-main` ruleset 已建但**免费版组织私有仓库不执法，至少需升级 GitHub Team**；这只解决 ruleset
  执法，不满足私有 Environment required reviewer 合同，后者仍需 Enterprise 能力或经审计的外部双人审批/
  离线签名替代设计。`protect-release-tags` 与两个 Environment 未建；Quality Gate #58（main@bd70d7f）
  Secret scan/Backend 双红（前者为已定性测试常量误报待豁免，后者根因待日志）。负责人决定配置推迟。
  这些外部 authority 未补齐前
  禁止 push 受保护分支、tag/dispatch。任何 dirty 本地构建、旧摘要或脚本测试都不能替代这些证据。
- 当前操作者离开内网时，可以继续完成源码、文档、测试、构建、签名候选和 CI；没有已验收 VPN/零信任
  通道时，不能完成目标机写入、重启、HTTPS 登录、故障注入和内部测试 GO。不得临时暴露公网端口。

### 8.1 当前冻结准备证据（源码候选验证，非发布证据）

以下均为本机实测，只登记为**源码候选层**；受审提交/tag、CI 签名、OSS 回读、目标机证据仍未形成。

| 门禁 | 结果 |
|---|---|
| 服务端最终 `clean verify` | Surefire **401 套 / 1714 项，0 失败 0 错误，2 项按门控跳过**；Failsafe 双 JAR 打包门禁 2/2 |
| Flutter 全量测试 / analyze | **729/729 通过**；全仓 `flutter analyze --no-pub` 零问题 |
| 双 JAR / Flyway | app 与 migrator JAR 各含 **270 条迁移、head V289**，与工作树和 checksum manifest exact-set 一致；migrator Main-Class 正确 |
| 部署链 | 五组 Python 门禁合计 **909 项，0 失败 0 错误**；这仍不是目标机或远端 CI 证据 |
| 真实公司克隆迁移 | 因缺少 OOB 身份、备份摘要和批准引用而按设计跳过；不得把跳过解释为通过 |

### 8.2 两份外部 authority 配置清单

1. 解除“禁止 push/tag/dispatch”所需的 GitHub、人员 Commit/Tag 签名、Release 制品签名、Environment、
   OIDC/OSS 配置与读回证据：
   [release/GITHUB_SIGNING_AND_PROTECTION_SETUP.zh-CN.md](release/GITHUB_SIGNING_AND_PROTECTION_SETUP.zh-CN.md)。
2. 允许首次目标机只读连接所需的 CMDB、带外 Host Key、两把管理员公钥、VPN/VLAN、控制台、口令轮换和
   H01–H12 证据：
   [target-host-oob-authority.zh-CN.md](target-host-oob-authority.zh-CN.md)。

任一清单未完成都保持对应链路 NO-GO。GitHub authority 完成不能替代目标 OOB；目标 OOB 完成也不能替代
受保护提交、签名发布和 OSS readback。
