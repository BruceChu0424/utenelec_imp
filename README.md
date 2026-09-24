# Uten IMP

> 优腾电器内部运营 ERP：销售、物料分析、采购与委外、生产执行、品质、仓库、财务，以及人事、访客、通知与权限管理，全部在一套系统内闭环。

| 项目 | 当前值 |
|---|---|
| 当前版本 | 服务器 **v2.0.1**(库 V688, 2026-09-24 部署); main 已含 V689-V692, 下一版 v2.0.2 |
| 数据库迁移头 | **V692** / 621 个迁移文件(V648-V669 跳号); 新迁移从 V693 起, 新 ADR 从 ADR-116 起 |
| 前端 | Flutter 3.44.2 / Dart 3.12.2(Web、Windows、macOS、Linux、Android、iOS) |
| 后端 | Java 21、Spring Boot 3.5.16、PostgreSQL 16、Flyway |
| 发布方式 | GitHub Actions 签名构建 → 阿里云 OSS → 服务器更新器拉取激活([ADR-060](docs/99-决策记录-ADR/ADR-060-单维护者简化发布链与旧发布链退役.md)) |

**接手先读**: [全平台整改交接总览](docs/99-项目治理/全平台整改交接/01-交接总览.md)(现在在做什么、做完什么、下一步怎么做; 云端 Claude 另读[逐项续做指引](docs/99-项目治理/全平台整改交接/06-云端Claude逐项续做指引.md)) → [准则索引与开发清单](docs/00-项目准则/00-准则索引与开发清单.md) → [文档索引](docs/README.md)。

---

## 目录

- [业务范围](#业务范围)
- [技术架构](#技术架构)
- [仓库结构](#仓库结构)
- [快速开始](#快速开始)
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
| 仓库与品质 | 入库、领料、调拨、线边仓直送、先入库后质检、质检处置、库存实际成本 | `lib/features/warehouse`、`lib/features/quality`、`server/.../features/stock` |
| 财务 | 收付款、应收应付结算、银行账户流水、报销、工资、总账附表 | `lib/features/finance`、`lib/features/expense`、`lib/features/payroll` |
| 组织与平台 | 员工与人事档案、部门树、访客、通知、工作台徽章、页面与数据范围权限、审计、系统设置 | `lib/features/admin`、`lib/features/dashboard`、`server/.../features/admin` |

每条业务规则到页面、服务函数、迁移与测试的对照表见[文档索引](docs/README.md#业务到实现)。

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

## 仓库结构

```
.
├─ lib/                 Flutter 前端: core(网络/主题/路由) · components(公共组件) · shared · features(业务页面)
├─ test/                Flutter 单元与 Widget 测试
├─ server/              Spring Boot 后端(独立 Maven 工程, 见 server/README.md)
│  ├─ src/main/resources/db/migration   Flyway 正式迁移(唯一的表结构来源)
│  ├─ ops/              运维 SQL(业务数据重置等)
│  └─ legacy_migration/ 旧系统(YTDQ)数据导入脚本; 原始备份不入库, 由 UTEN_LEGACY_INPUT_DIR 指定
├─ deploy/              部署: simple/(现役发布与运行手册) · updater · nginx · systemd · postgres · ocr
├─ website/             官网独立工程(Node 22)
├─ docs/                项目文档(准则、组件、页面、数据模型、架构、业务链路、ADR、迁移、治理)
└─ .github/workflows/   CI 质量门禁、CodeQL、依赖漏洞扫描、签名发布
```

## 快速开始

### 前置条件

| 工具 | 版本 |
|---|---|
| Flutter / Dart | 3.44.2 / 3.12.2(通过 `PATH` 或 `FLUTTER_HOME` 配置, 不写死个人路径) |
| JDK / Maven | 21 / 3.9+ |
| Docker | 本地 PostgreSQL 与数据库测试(Testcontainers)需要 |

### 1. 启动后端

```bash
cd server
cp .env.example .env              # 私有配置: 数据库、JWT 密钥、UTEN_PROFILE=dev 等; 不得提交
docker compose up -d postgres     # PostgreSQL 16, 宿主端口 5433
mvn spring-boot:run               # 启动时 Flyway 自动迁移到最新
```

API 位于 `http://localhost:8080/api`, dev 下 Swagger 位于 `/swagger-ui.html`。首次引导超管、端口约定与排错见[后端说明](server/README.md)。

### 2. 启动前端

```bash
flutter pub get
flutter run -d chrome --web-port=53764 --dart-define=API_BASE_URL=http://localhost:8080/api
```

Debug 默认 API 即 `http://localhost:8080/api`; 桌面端把 `-d chrome` 换成 `-d windows` / `-d macos`。

## 质量门禁与测试

CI(`.github/workflows/quality.yml`)在每次推送 main 与每个 PR 上运行, 发布门禁要求同一提交的质量门禁、CodeQL、依赖漏洞扫描全部通过:

| CI 作业 | 本地等价命令 |
|---|---|
| Flutter / Web | `dart format --output=none --set-exit-if-changed lib test` → `flutter analyze` → `flutter test` |
| Backend 快道(单元 + 架构 + 契约) | `cd server && mvn verify` |
| Backend 全量(真库 + 全链路) | `cd server && UTEN_RUN_DB_TESTS=true mvn verify`(Docker/Testcontainers, 约 1.5-2 小时) |
| Deployment contracts | `python -m unittest discover -s deploy/updater -p "test*.py"`(以及 `deploy/postgres/backup`、`deploy/setup`) |
| Website / Node 22 | `cd website && node scripts/quality-gate.mjs` |
| Secret history scan | gitleaks 全历史扫描 |

> **本地验证必须与 CI 同口径**: CI 没有 `server/.env`, 未设 `UTEN_PROFILE` 时后端按 `prod` 启动(fail-closed)。在本机跑后端门禁前先把 `server/.env` 挪开, 否则 `dev` profile 会掩盖只在 `prod` 口径暴露的问题。

业务正确性的主证据是 [`FullChainEndToEndTest`](server/src/test/java/com/uten/imp/businesschain/FullChainEndToEndTest.java)(160 个跨模块全链路场景, 真实 PostgreSQL, 切换账号走完整安全链)。定向测试只证明对应场景, 发布前必须在同一候选提交上完成全量检查。

## 数据库迁移规则

- 表结构只来自 [`server/src/main/resources/db/migration`](server/src/main/resources/db/migration); 已应用的迁移**永不修改字节**, 修正一律向前追加。
- 新迁移号必须大于当前迁移头(main 在 V692, 服务器在 V688; 更小的号会被 Flyway 判为乱序拒绝启动)。开号前先查目录与在途分支, 避免撞号。
- 新增表必须同时登记: 审计三清单、业务数据重置脚本的表分类、主档引用目录(若引用主档); 迁移头变化要同步五处契约(见[编排方法与验收](docs/99-项目治理/全平台整改交接/04-编排方法与验收.md))。
- 每个迁移有对应说明, 索引见[数据迁移](docs/数据迁移/README.md)。
- 生产迁移只经发布更新器执行(先自动全量备份)。**不要在服务器上直接运行 migrator 做演练**: 它固定连接正式库; 演练在开发机的库副本上进行。

## 安全与权限

- 认证: Argon2id 密码; JWT 绑定服务端会话(`sid`), 登出、改密、停用、离职即时失效; 登录限流与锁定, 锁定期对错同码。
- 敏感操作(授权、重置密码、模拟身份、系统设置、清空业务数据等)要求 5 分钟内一次性再认证。
- 授权: 权限目录单一事实源 + 部门/个人授权 + 对象级数据范围; 前端隐藏按钮只是体验, 服务端逐请求校验。
- 数据: SQL 全部参数化; 员工敏感字段加密与按权限脱敏; 审计只追加且运行账号不能改删。
- 密钥只经受控环境注入(`server/.env` 仅限本机开发且不入库); 详见[安全准则](docs/00-项目准则/10-安全准则.md)。

## 发布与部署

现役流程([运行手册](deploy/simple/RUNBOOK.zh-CN.md)):

1. 候选提交在本地与 CI 全部门禁通过, 迁移已在开发机的服务器库副本上演练。
2. `gh workflow run simple-release.yml --ref main -f version=vX.Y.Z`: 构建、签名、上传 OSS。
3. 服务器: `sudo uten-imp-updater check`(下载验签暂存) → 更新 `server.env` 中的版本号 → `sudo uten-imp-updater activate vX.Y.Z`(自动备份 → 迁移 → 原子切换 → 健康检查, 失败自动回滚)。
4. 冒烟验证核心接口, 查看服务器状态页(审计留存、后台任务、5xx、慢请求)。

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

- 提交与合并遵守 [Git 提交与合并规范](docs/00-项目准则/11-Git提交与合并规范.md); 并行开发各用独立 worktree, 不在同一工作区交叉提交。
- 改动完成后同步相关文档(页面说明、ADR、迁移说明、实体字典)。
- 修复要定位到根因, 不打补丁; 同一口径只在服务端算一次。
