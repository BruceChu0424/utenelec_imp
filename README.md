# Uten IMP

先读[准则索引与开发清单](docs/00-项目准则/00-准则索引与开发清单.md)。业务、页面、源码、迁移和测试的统一导航在[文档索引](docs/README.md)。

Uten IMP 是面向企业内部运营的 ERP，前端使用 Flutter，后端使用 Spring Boot、PostgreSQL 和 Flyway。业务围绕销售财审、物料分析、采购/委外、生产、品质、仓库和财务事实衔接，兼有 HR、访客、通知和权限管理。

本轮实现与验收状态集中维护在[全平台本地审计与整改验收](docs/99-项目治理/2026-09-07-全平台本地审计与整改验收.md)，优先顺序见[执行纠偏与串行收口](docs/99-项目治理/2026-09-07-执行纠偏与串行收口.md)。源码候选、隔离测试、GitHub发布和服务器安装分别留证，历史专项通过不能代替当前全量或部署结果。

## 本地开发

工具链通过 `PATH`、`FLUTTER_HOME`、`JAVA_HOME` 配置，不写死个人 SDK 路径。前端按仓库约定使用 Flutter 3.44.2 / Dart 3.12.2，依赖范围以 [pubspec.yaml](pubspec.yaml) 和 lockfile 为准；后端使用 Java 21、Spring Boot 3.5.16，版本以 [pom.xml](server/pom.xml) 为准。

先依[后端说明](server/README.md)配置本地 PostgreSQL、环境变量和服务。连接及密钥只从受控环境配置注入；不使用演示凭据、不把真实密钥写进仓库。前端 Debug 默认 API 为 `http://localhost:8080/api`，也可明确传入：

```powershell
flutter pub get
flutter run --dart-define=API_BASE_URL=http://localhost:8080/api
```

从仓库根目录执行前端检查：

```powershell
flutter analyze
flutter test
```

数据库测试需 Docker 和隔离测试库。在 `server/` 下显式启用 PostgreSQL 测试：

```powershell
$env:UTEN_RUN_DB_TESTS='true'
mvn verify
```

定向测试只能证明对应场景。共享工作区先检查未提交改动，格式化只作用于本任务的明确文件；发布前按准则完成同一候选的完整检查。迁移只读[正式资源目录](server/src/main/resources/db/migration)和[数据迁移说明](docs/数据迁移/README.md)，不把旧草案目录或临时SQL原型当成当前应用资源。

## 代码与文档入口

| 内容 | 入口 |
|---|---|
| Flutter业务页面、模型、仓储 | [lib/features](lib/features) |
| 共享组件、格式和网络能力 | [lib/shared](lib/shared)、[lib/core](lib/core)、[组件总览](docs/02-组件库/组件总览.md) |
| 后端事务服务与跨域端口 | [server/src/main/java/com/uten/imp](server/src/main/java/com/uten/imp)、[application/port](server/src/main/java/com/uten/imp/application/port) |
| 测试 | [test](test)、[server/src/test](server/src/test) |
| 业务规则→页面→函数→迁移→测试 | [docs/README.md](docs/README.md) |
| 官网独立工程 | [website](website) |

页面遵循共享[主题与配色](docs/00-项目准则/08-主题与配色.md)、[响应式规则](docs/00-项目准则/02-响应式与多端适配.md)、[性能自适应](docs/00-项目准则/07-性能自适应.md)和组件合同。字段错误/说明沿公共框内提示，实际金额原文、历史快照和权限脱敏由业务合同决定，不能为了显示方便修改权威值。

## 认证与交付

前端使用真实后端账号；首次登录要求改密时先完成改密。导航和操作受服务端权限、对象范围和版本约束，按钮隐藏不能替代服务端校验。Web标签页使用独立会话，具体注销、令牌撤销和跨标签规则见[ADR-061](docs/99-决策记录-ADR/ADR-061-多账号多标签页独立会话.md)与[安全准则](docs/00-项目准则/10-安全准则.md)。短暂网络失败不能冒充退出登录，写命令的重试必须遵守业务幂等合同。

当前发布方式依据[ADR-060](docs/99-决策记录-ADR/ADR-060-单维护者简化发布链与旧发布链退役.md)和[部署运行手册](deploy/simple/RUNBOOK.zh-CN.md)；六端签名、安装及端点规则见[多端发布与签名](docs/99-项目治理/多端发布与签名.md)。Git操作遵守[提交与合并规范](docs/00-项目准则/11-Git提交与合并规范.md)。服务器写入、备份恢复、迁移、业务对账及切换必须有各自实际执行证据，文档和脚本存在不表示已经部署。

文档使用中文为主的 Markdown，跨文档使用相对链接。长期规则放在准则/SOP，交互放在页面说明，正式决策放在ADR，迁移与兼容放在数据迁移专册，测试结果只写入相应验收记录；避免再建立重复的日期续作入口。
