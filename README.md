# Uten IMP

> 优腾电器内部运营 ERP：销售、物料分析、采购与委外、生产执行、品质、仓库、财务，以及人事、访客、通知与权限管理，全部在一套系统内闭环。

| 项目 | 当前值 |
|---|---|
| 源码候选与发布状态 | 本地集成候选 **2.5.48+2549**（核对基线：2026-11-05）；本轮仅进行源码整合和 CI 修复；正式打包、发布和服务器更新已取消。精确提交、启动、CI 与交付证据分别见[当前版本验证](docs/99-项目治理/当前版本验证.md)。 |
| 数据库迁移头 | 本地候选源码 **V1076 / 1015** 个迁移文件，Git HEAD 已跟踪 V1069/V1072/V1073 且近期齐号；按[迁移目录](server/src/main/resources/db/migration)与[迁移索引](docs/数据迁移/README.md)核对。目标库实际版本另查其 `flyway_schema_history`。三个并行任务若在本轮修复期间完成则审查纳入，不等待它们；“统一修复货品导出选择”已纳入。 |
| 前端 | Flutter 3.44.2 / Dart 3.12.2(Web、Windows、macOS、Linux、Android、iOS) |
| 后端 | Java 21、Spring Boot 4.1.1、PostgreSQL 16、Flyway |
| 发布方式 | GitHub Actions 签名构建 → 阿里云 OSS → 服务器更新器拉取激活([ADR-060](docs/99-决策记录-ADR/ADR-060-单维护者简化发布链与旧发布链退役.md)) |

**接手先读**: [全平台整改交接总览](docs/99-项目治理/全平台整改交接/01-交接总览.md)(现在在做什么、做完什么、下一步怎么做; 云端 Claude 另读[逐项续做指引](docs/99-项目治理/全平台整改交接/06-云端Claude逐项续做指引.md)) → [准则索引与开发清单](docs/00-项目准则/00-准则索引与开发清单.md) → [文档索引](docs/README.md)。

**服务器部署、换账号、换机和备份恢复**统一从[服务器部署、备份与迁移总手册](deploy/SERVER_MIGRATION.zh-CN.md)进入，先区分 ERP 云入口、公司 PostgreSQL 主机和广州旧站 MySQL；按成套恢复、目标先验证、唯一写主与明确回退步骤交接。现场状态、未启用方案和新旧备份控制脚本差异在手册中分别记录。

远程访问的源码与部署方案见[ADR-183](docs/99-决策记录-ADR/ADR-183-本地业务服务与受控远程入口.md)与[远程接入目录](deploy/remote-access/)。公司保留业务服务和唯一主库，云端只转运加密流量；员工访问按现行 `users.remote_access` 与业务权限判断。旧远程 MFA/总开关描述以 ADR 顶部 2026-10-29 修订为准；公司侧隔离、真实网络性能和实际发布验收继续保留。

---

## 目录

- [业务范围](#业务范围)
- [技术架构](#技术架构)
- [仓库结构](#仓库结构)
- [快速开始](#快速开始)
- [本地数据重建与导入](#本地数据重建与导入)
- [质量门禁与测试](#质量门禁与测试)
- [数据库迁移规则](#数据库迁移规则)
- [安全与权限](#安全与权限)
- [发布与部署](#发布与部署)
- [版本号规则](#版本号规则)
- [文档体系](#文档体系)
- [协作规范](#协作规范)

---

## 业务范围

| 领域 | 主要能力 | 代码入口 |
|---|---|---|
| 销售 | 订单与财务审核、现货预留、分批出货、出货财审与仓库作业、退货品质处置、应收 | `lib/features/sales`、`server/.../features/sales` |
| 生产计划 | 物料分析(一张表直接下单、BOM 展开、缺口与下达)、自底向上计划、车间任务与三种供料路线 | `lib/features/production`、`server/.../features/production` |
| 采购与委外 | 申请、订货、到货登记、IQC、退换货、委外出仓回厂、短交判定与损耗结清 | `lib/features/purchase`、`lib/features/subcontract` |
| 仓库与品质 | 入库、领料、调拨、线边仓直送、先入库后质检、质检处置、库存实际成本；仓库重量账(数量后称重、六种重量单位自动换算、估算带「≈」未称不当 0、每个货品完整出入库明细账)、单重自学习与称重计数、库存分析(呆滞与库龄、盘点建议、称重异常) | `lib/features/warehouse`、`lib/features/quality`、`lib/shared/measurement`、`lib/shared/stock_ledger`、`server/.../features/stock` |
| 财务 | 收付款、应收应付结算、银行账户流水、报销、工资、总账附表 | `lib/features/finance`、`lib/features/expense`、`lib/features/payroll` |
| 组织与平台 | 员工与人事档案、部门树、访客(访客门户前端已下线，后端与员工侧审批保留)、通知、工作台徽章、页面与数据范围权限、审计、系统设置 | `lib/features/admin`、`lib/features/dashboard`、`server/.../features/admin` |

每条业务规则到页面、服务函数、迁移与测试的对照表见[文档索引](docs/README.md#业务到实现)。

仓库重量账只给仓库用，数量仍是计划、成本、预留与财务的唯一事实，重量永不拦截数量过账：
到货登记、产成品登记、仓库单据与盘点、领料 / 退料、销售出库、委外出仓在数量后加「实称重量」列(可直接输 850g、1.2t、3斤)；
即时库存重量按显示单位换算并由服务端合计；库存详情与货品详情共用「库存余额 | 出入库流水 | 单重学习」面板；
系统从称样、盘点、到货等独立点数的称重里按供应商学单重(稳健剔除离群、换批检测、给出可靠度)，称重计数按单重折算件数并给区间；
新页面「库存分析」(`/warehouse/insights`)与手机用的「称重计数」(`/warehouse/weigh-count`)。决策见
[ADR-135](docs/99-决策记录-ADR/ADR-135-仓库重量账与单重自学习.md)，迁移见 [V743 说明](docs/数据迁移/261-V743-仓库重量账与单重学习.md)。

## 技术架构

```
 Flutter 客户端(Web / 桌面 / 移动)
   │  Riverpod 状态 · go_router 路由 · Dio 网络层 · 统一组件库(lib/components)
   │  HTTPS(内网 Nginx, HTTP/2)
   ▼
 Spring Boot 模块化单体(server/)
   │  features/<领域>  ──仅经 application.port 跨域调用(ADR-017, 架构测试锁边)
   │  统一安全链: 服务端会话 + 权限目录 + 对象范围 + 敏感操作再认证
   │  统一写路径: 事务级预锁发现一次 + (id, xmin) 复核 + 可重跑 409(ADR-107)
   ▼
 PostgreSQL 16(Flyway 管理全部结构; Hibernate 只做 validate)
      守卫触发器兜底业务不变量 · 审计按月分区只追加(ADR-105)
```

关键设计决策(均有 ADR, 见 [ADR 索引](docs/99-决策记录-ADR/README.md)):

| 主题 | 决策 |
|---|---|
| 并发与一致性 | [ADR-107](docs/99-决策记录-ADR/ADR-107-履约预锁一轮发现与服务端截止时间.md): 每个写事务只做一次依赖发现, 锁后按 `(id, xmin)` 复核; 数据库侧 `lock_timeout 10s / statement_timeout 60s`, 超时与死锁统一转为可重试的 409 |
| 审计 | [ADR-105](docs/99-决策记录-ADR/ADR-105-审计白名单行级审计与分区留存.md): 行级审计三清单(全量/限定列/不审计), 只记变化; 按月分区、运行账号不能改删; 留存有 6 个月法定下限并可证实执行 |
| 权限 | [ADR-109](docs/99-决策记录-ADR/ADR-109-权限目录单一事实源与授权策略.md): 权限目录与授权策略单一事实源, 按钮隐藏不替代服务端校验 |
| 会话与再认证 | [ADR-110](docs/99-决策记录-ADR/ADR-110-服务端会话与敏感操作再认证.md): 服务端会话(登出/改密/停用即失效), 高危操作 5 分钟一次性再认证 |
| 金额 | [ADR-112](docs/99-决策记录-ADR/ADR-112-金额口径统一与资金过账单一入口.md): 金额只由服务端精确派生; 分批按"累计份额、末批取余"保证合计等于原单 |
| 前端性能 | [ADR-108](docs/99-决策记录-ADR/ADR-108-前端性能徽章汇总会话快照与刷新时机.md): 全站徽章一次汇总、会话快照、返回即刷新按需 |
| 表格与学习 | [ADR-137](docs/99-决策记录-ADR/ADR-137-全平台可扩展表格与统一投影.md)：公共动态列、精确计算、权限与历史快照、预览/下载同表头；[ADR-136](docs/99-决策记录-ADR/ADR-136-业务扩展列与客户报价模板学习.md)：商业费用及客户报价模板 |

## 仓库结构

```
.
├─ lib/                 Flutter 前端: core(网络/主题/路由) · components(公共组件) · shared · features(业务页面)
├─ test/                Flutter 单元与 Widget 测试
├─ server/              Spring Boot 后端(独立 Maven 工程, 见 server/README.md)
│  ├─ src/main/resources/db/migration   Flyway 正式迁移(唯一的表结构来源)
│  ├─ ops/              数据库账户、备份与运维维护脚本
│  └─ legacy_migration/ 旧系统(YTDQ)数据导入脚本; 原始备份不入库, 由 UTEN_LEGACY_INPUT_DIR 指定
├─ deploy/              发布、客户端交付、备份、远程接入及运维；现役入口为 simple/RUNBOOK 与 SERVER_MIGRATION，各子目录按其顶部适用范围区分现役工具和归档旧链
├─ scripts/             仓库级辅助脚本(平台表清单审计、表键登记、特性分支发布等)
├─ website/             官网独立工程(Node 22)
├─ docs/                项目文档(准则、组件、页面、数据模型、架构、业务链路、ADR、迁移、治理)
└─ .github/workflows/   CI 质量门禁、CodeQL、依赖漏洞扫描、签名发布
```

## 快速开始

### 前置条件

| 工具 | 版本 |
|---|---|
| Flutter / Dart | 3.44.2 / 3.12.2(通过 `PATH` 或 `FLUTTER_HOME` 配置, 不写死个人路径) |
| JDK / Maven | 21 / 3.9.7+ |
| Docker | 本地 PostgreSQL 与数据库测试(Testcontainers)需要 |

### 1. 启动后端

先按[后端说明](server/README.md#快速开始)准备本地数据库、角色、附件目录及私有 `.env`；已有 `.env` 保留原字节，不覆盖或打印凭据。新空环境模板使用宿主端口 `5433`；已有导入实例可能使用 `5434`，实际连接由受控配置决定，不能据 README 猜测或切换数据库。

在仓库根目录执行：

```powershell
.\server\dev.ps1
```

也可在 `server/` 执行 `mvn -Pdev-run spring-boot:run`。`dev-run` 只用于开发启动，独立输出到 `target-dev`，跳过测试编译；验收、CI 和打包不得携带该 profile。并行实例使用各自构建目录与端口，数据库和附件仍须另行隔离，见[启动与并行测试](server/README.md#本地启动与并行测试的编译目录)。

开发环境显式设置 `UTEN_PROFILE=dev`，由非超级用户的专用迁移账号执行 Flyway，应用连接池继续使用受限运行账号；`prod` 不靠重启自动迁移。等待 Flyway 完成、`Started UtenImpApplication` 及 `/actuator/health/readiness` 返回 `200/UP`，再核对前端实际请求。API 默认 `http://localhost:8080/api`；dev Swagger 为 `/swagger-ui.html`。

迁移重号、缺表、历史 checksum 或角色错误按后端排错步骤保留证据并处理，不执行 `repair`、跳过迁移或关闭守卫。源码、生成资源和真实数据库是三个检查对象；旧构建目录中的未发布候选 SQL 不能混入本次启动。

### 2. 启动前端

另开一个终端，工作目录为仓库根目录（含 `pubspec.yaml`），不要沿用上一步的 `server/` 目录。

```bash
flutter pub get --enforce-lockfile
flutter run -d chrome --web-port=53764 --dart-define=API_BASE_URL=http://localhost:8080/api
```

仓库 `pubspec.lock` 的 hosted 来源统一为默认 `https://pub.dev`。正式验证、CI 与发行构建不设置 `PUB_HOSTED_URL`，使用 `--enforce-lockfile` 核验同一锁文件的版本、来源和归档 SHA-256；缺锁、约束不匹配或内容哈希变化直接失败。个人镜像实验应使用独立目录，不能把镜像改写的锁文件用于提交或发布。依赖更新须单独审查并提交锁文件，再运行完整门禁。

Debug 默认 API 即 `http://localhost:8080/api`; 桌面端把 `-d chrome` 换成 `-d windows` / `-d macos`。

不自动打开浏览器时可使用 `flutter run -d web-server --web-hostname=127.0.0.1 --web-port=53764 --dart-define=API_BASE_URL=http://localhost:8080/api`，随后访问输出地址，确认实际页面渲染和接口请求成功。如果使用其它端口，确认后端 CORS 允许前端实际来源；已有服务占用端口时选择空闲端口，不终止不属于本次验证的进程。

现役 Web 发行物采用 JavaScript / CanvasKit，构建命令为：

```bash
flutter build web --release --no-pub --no-web-resources-cdn --no-wasm-dry-run --dart-define=API_BASE_URL=/api
```

`--no-wasm-dry-run`关闭未采用的 WebAssembly 目标预检查；JavaScript 编译、静态分析、测试和字体完整性校验继续执行。这不表示 WebAssembly 兼容性已通过，安全存储依赖也不因此升级大版本。

## 本地数据重建与导入

[重建彩排与正式导入执行手册](docs/数据迁移/重建彩排与正式导入执行手册.md)保留各批次来源、实际 COMMIT、保护范围和恢复证据。旧手册或旧 README 中带日期的 `RUNNING` / `PENDING` 只代表当时记录，不能据此判断当前导入仍在运行、已经完成或获准重放。先核对目标实例及后继实际回执，不清库、不重放已经成功的阶段。

货品迁移以旧数据库的已有非空同义字段为先，价格 `0` 也算已有值；产品 Excel 只补真正缺失的属性和独有货品，冲突保留原文和源行，金额精度及单位冲突按[货品溯源规则](docs/数据迁移/2026-11-03-货品价格溯源与数据库优先修复.md)处理。历史单据的只读展示与现代履约接续分别验收，不能把源码候选或一次启动当作公司换库、完整导入或业务 UAT 已完成。

## 质量门禁与测试

CI(`.github/workflows/quality.yml`)在每次推送 main 与每个 PR 上运行, 发布门禁要求同一提交的质量门禁、CodeQL、依赖漏洞扫描全部通过:

| CI 作业 | 本地等价命令 |
|---|---|
| Flutter / Web | 完整 `test/**_test.dart` 分8片、最多4片并发；format/analyze/issuer/Chrome 6文件/Web构建并行，原required检查聚合所有门禁及同SHA VM与Chrome machine报告；[完整核对规则](docs/00-项目准则/15-全量测试分片与耗时核对.md#flutter完整文件分片) |
| Backend 快道(单元 + 架构 + 契约) | `cd server && mvn -Duten.build.directory=target-fast verify` |
| Backend 全量(真库 + 全链路) | CI完整发现后分16片、最多16片并发；本地原入口 `cd server && UTEN_RUN_DB_TESTS=true mvn verify`(Docker/Testcontainers；完整发现、分片与汇总见[测试规范](docs/00-项目准则/15-全量测试分片与耗时核对.md)) |
| Deployment contracts | `python -m unittest discover -s deploy/updater -p "test*.py"`(以及 `deploy/postgres/backup`、`deploy/setup`、`deploy/monitoring`、`deploy/aliyun-oidc`、`deploy/ocr`；模板校验 `pwsh deploy/verify-templates.ps1`) |
| Website / Node 22 | `cd website && node scripts/quality-gate.mjs` |
| Secret history scan | gitleaks 全历史扫描 |

> **本地验证必须与 CI 同口径**：优先在不复制私有 `.env` 的冻结工作树验证，使用独立构建目录。CI 没有 `server/.env`，未设 `UTEN_PROFILE` 时按 `prod` 失败关闭；不让本机 dev 配置掩盖差异，也不移动或覆盖运行服务使用的私有配置。具体原生 Windows、Android、浏览器草稿、部署合同和 Web 构建检查以工作流为准，表中命令不是完整门禁清单。

业务正确性的主证据是 [`FullChainEndToEndTest`](server/src/test/java/com/uten/imp/businesschain/FullChainEndToEndTest.java)(跨模块全链路场景, 真实 PostgreSQL, 切换账号走完整安全链)。定向测试只证明对应场景, 发布前必须在同一候选提交上完成全量检查。

## 数据库迁移规则

- 表结构只来自 [`server/src/main/resources/db/migration`](server/src/main/resources/db/migration); 已应用的迁移**永不修改字节**, 修正一律向前追加。
- 业务数据清空功能已彻底删除，开发环境也不保留入口；V919 前向迁移删除数据库清空函数、专用权限和历史保护绕过分支。历史 SQL 保留原字节供 Flyway 校验，不能作为恢复清空能力的依据，见 [ADR-192](docs/99-决策记录-ADR/ADR-192-业务数据清空功能永久删除.md)。
- 新迁移号必须大于当前源码迁移头。开号前先查目录与在途修改，目标服务器版本另查其 `flyway_schema_history`；不能用历史部署记录或本地文件数推断。
- 新增表必须同时登记审计三清单、主档引用目录(若引用主档)；不再扩展已删除的业务清空分类或恢复其函数。迁移头变化同步 [docs/数据迁移/README.md](docs/数据迁移/README.md)，历史迁移合同只验证对应历史版本。
- 每个迁移有对应说明, 索引见[数据迁移](docs/数据迁移/README.md)。
- 生产迁移只经发布更新器执行(先自动全量备份)。**不要在服务器上直接运行 migrator 做演练**: 它固定连接正式库; 演练在开发机的库副本上进行。

## 安全与权限

- 认证: Argon2id 密码; JWT 绑定服务端会话(`sid`), 登出、改密、停用、离职即时失效; 登录限流与锁定, 锁定期对错同码。
- 敏感操作(授权、重置密码、模拟身份、系统设置等)要求 5 分钟内一次性再认证。
- 授权: 权限目录单一事实源 + 部门/个人授权 + 对象级数据范围; 前端隐藏按钮只是体验, 服务端逐请求校验。
- 数据: SQL 全部参数化; 员工敏感字段加密与按权限脱敏; 审计只追加且运行账号不能改删。
- 密钥只经受控环境注入(`server/.env` 仅限本机开发且不入库); 详见[安全准则](docs/00-项目准则/10-安全准则.md)。

## 发布与部署

现役流程([运行手册](deploy/simple/RUNBOOK.zh-CN.md)):

1. 候选提交在本地与 CI 全部门禁通过, 迁移已在开发机的服务器库副本上演练。
2. 已支持的客户端平台随本版一并打包；当前 Windows 从同一正式 Release 输出生成 `Setup.exe` 和更新 ZIP，版本及构建号一致，使用正式公司/远程连接配置。命令和校验见[客户端发布手册](deploy/client/README.zh-CN.md)，本地测试包不能上传为正式版本。
3. `gh workflow run simple-release.yml --ref main -f version=vX.Y.Z`: 构建、签名、上传服务端及 Web 到 OSS；该工作流不能代替 Windows 双包构建和客户端授权发布。
4. 服务器: `sudo uten-imp-updater check`(下载验签暂存) → 更新 `server.env` 中的版本号 → `sudo uten-imp-updater activate vX.Y.Z`(自动备份 → 迁移 → 原子切换 → 健康检查, 失败自动回滚)。
5. 持有 `client_release:publish` 权限的人员通过客户端发布入口将两份正式包上传、发布至 `UTEN_CLIENT_RELEASES_DIR`。同版本、同架构的安装包和 ZIP 均验证并发布成功后，发布服务删除更低版本的已发布二进制，只保留最新完整一组；保留审计元数据，失败时保留上一组。
6. 冒烟验证核心接口和服务器状态页，并核对最新安装包下载、客户端更新 ZIP 与旧包清理结果，全部完成后再标记本版交付完成。

多端签名与安装见[多端发布与签名](docs/99-项目治理/多端发布与签名.md)。

## 版本号规则

语义化 `vMAJOR.MINOR.PATCH`: 不兼容调整升 MAJOR(例如 v2.0.0 要求全员重新登录、权限码改名), 新增功能升 MINOR, 问题修复升 PATCH。自 2026-09-18 起生效, 首个语义化版本为 `v1.0.0`, 此前的日期号 `vYYYY.MM.DD-N` 不再接受。

发布内部序号(`releaseSequence`)由 `deploy/updater/release_guard.py`、`deploy/release/release_tools.py`、`deploy/release/offline_release.py` 三处孪生函数按同一编码折算, 三处必须逐位一致, 改一处须同步另外两处。

## 文档体系

| 目录 | 内容 |
|---|---|
| [00-项目准则](docs/00-项目准则/00-准则索引与开发清单.md) | 命名、组件、响应式、性能、权限、安全、Git 等全局规范 |
| [02-组件库](docs/02-组件库/组件总览.md) | 公共组件的行为与使用约定 |
| [03-页面](docs/03-页面/页面总览.md) | 每个页面的入口、字段、权限、动作与错误反馈 |
| [04-数据模型](docs/04-数据模型) / [05-架构](docs/05-架构) | 实体字典、ER 图、架构说明 |
| [07-业务链路](docs/07-业务链路) | 业务 SOP 与场景矩阵 |
| [ADR 索引](docs/99-决策记录-ADR/README.md) | 正式架构与业务决策 |
| [数据迁移](docs/数据迁移/README.md) | 每个迁移的目的、影响与兼容说明 |
| [全平台整改交接](docs/99-项目治理/全平台整改交接/01-交接总览.md) | 整改背景、已完成内容、后续工作流任务书、验收方法 |

文档以中文 Markdown 为主, 跨文档使用相对链接; 新增内容一律使用 ASCII 半角括号。长期规则写进准则, 交互写进页面说明, 正式决策写成 ADR, 测试结论只写入对应验收记录。

## 协作规范

前端/UI 相关代码和设计文档默认使用 `frontend-design`；`ui-ux-pro-max` 仅在用户明确指定时使用。技能入口与执行规则见 [AGENTS.md](AGENTS.md)，详细范围见[设计技能选择](docs/00-项目准则/00-准则索引与开发清单.md#设计技能选择)。

- 提交与合并遵守 [Git 提交与合并规范](docs/00-项目准则/11-Git提交与合并规范.md); 并行开发各用独立 worktree, 不在同一工作区交叉提交。
- 改动完成后同步相关文档(页面说明、ADR、迁移说明、实体字典)。
- 修复要定位到根因；按[统一实现与公共能力](docs/00-项目准则/16-统一实现与公共能力.md)比较已有方案、迁移全部适用调用方并验证，业务权威计算集中在正确的服务端入口，保留必要业务差异及 B0 响应性保护。各阶段持续统一，B4 做全项目覆盖复核；小阶段之间按本会话额度规则持续推进。
