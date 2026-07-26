# 老库数据迁移 · 总索引

> 本文件夹是「老库 `YTDQ_2023` → 新库」数据迁移的**执行中心**。
> 看本 README 就懂：每个模块迁什么、代码在哪、怎么一键迁移、怎么加新模块。
> 融合策略（为什么单向影子双写等）见 [../06-老系统融合/00-融合总策略.md](../06-老系统融合/00-融合总策略.md)。

---

## 🚀 一键迁移（平台上线后直接用）

**前提**：老库可达（dev = 本机 LocalDB 已还原 `YTDQ_2023`；prod = 生产 SQL Server），并配好 `app.legacy.*`。

```bash
# 1. 启动 server 时打开迁移开关
UTEN_LEGACY_ENABLED=true mvn -f server/pom.xml spring-boot:run

# 2. 超管 token 触发一键迁移（幂等，可反复重跑）
curl -X POST http://localhost:8080/api/admin/legacy-migration/all \
  -H "Authorization: Bearer <超管token>"
# → { "modules": { "materialCategory.goods": {...}, "mould.category": {...}, "client.category": {...}, "supplier.category": {...} }, "success":true }
#   注：Java 端点只迁「分类树」（4 棵 SystemItem 树）；「主档」（B_Goods/B_Mould/B_Client/B_Provider）
#   不走 Java，用下面 shell 的 --xxx-data 步骤灌入（批量 \copy CSV）。
```

**代码直接调用**：`LegacyMigrationOrchestrator.migrateAll()`
（`server/src/main/java/com/uten/imp/legacy/migration/LegacyMigrationOrchestrator.java`）

**增量同步**：老库新增数据后，**再调一次同一端点**即可——按 `legacy_id` 幂等 upsert，已存在的更新、新增的插入。

单模块排错（分类）：`POST /api/admin/legacy-migration/{material-category|client-category|supplier-category|mould-category}`。
主档排错（shell）：`bash server/legacy_migration/migrate.sh --{goods|mould|client|supplier}-data`（颜色/单位：`--color-data` / `--unit-data`，扁平无分类）。

> **⚠️ 数据坑（已修，迁其他含地址/备注的表时复用）**：老库 varchar 字段（地址、收货地址、备注）
> 可能含管道符 `|`。`export_legacy.ps1` 的 `Export-Query` 已做 RFC4180 引号转义（字段含
> 分隔符/引号/换行则 `"..."` 包裹、内部 `"`→`""`），配合 COPY `FORMAT csv` 正确还原。
> 不转义会 `missing data for column X`（客户主档首跑即踩）。

---

## 📦 模块清单

| 模块 | 状态 | 老库来源 | 新库表 | 迁移代码 | 文档 |
|---|---|---|---|---|---|
| **货品分类** | ✅ 已实现 | `SystemItem` (ItemclassID=1) | `material_categories` | `migrate.sh --goods` | [02-老库溯源](02-货品分类-老库溯源.md) · [03-新库与迁移](03-货品分类-新库与迁移.md) |
| **货品主档** | ✅ 已实现 | `B_Goods`（35750 条，全 78 字段，image 留空） | `goods` | `migrate.sh --goods-data` | （字段映射见 V32__goods.sql） |
| **模具分类** | ✅ 已实现 | `SystemItem` (ItemclassID=18，65 扁平根) | `mould_categories` | `migrate.sh --mould` | [04-老库溯源](04-模具资料-老库溯源.md) · [05-新库与迁移](05-模具资料-新库与迁移.md) |
| **模具主档** | ✅ 已实现 | `B_Mould`（1605 条，12 字段） | `moulds` | `migrate.sh --mould-data` | （字段映射见 V34__mould.sql） |
| **颜色** | ✅ 已实现 | `B_Color`（151 条，**实测扁平**非树；`B_Goods.MColorID` 引用） | `colors` | `migrate.sh --color-data` | [10-老库溯源](10-颜色资料-老库溯源.md) · [11-新库与迁移](11-颜色资料-新库与迁移.md) |
| **基本单位** | ✅ 已实现 | `B_Unit`（66 条，扁平，与 B_Color 同构；`B_Goods.UnitID` 引用） | `units` | `migrate.sh --unit-data` | [12-老库溯源](12-基本单位-老库溯源.md) · [13-新库与迁移](13-基本单位-新库与迁移.md) |
| 模具 | ✅ 见上 | — | — | — | （已拆为「模具分类 + 模具主档」两行） |
| 员工 | ⏳ 待做 | `B_Worker` | `employees` | 待 | — |
| **客户分类** | ✅ 已实现 | `SystemItem` (ItemclassID=2，10根/40节点/深3) | `client_categories` | `migrate.sh --client` | [06-老库溯源](06-客户资料-老库溯源.md) · [07-新库与迁移](07-客户资料-新库与迁移.md) |
| **客户主档** | ✅ 已实现 | `B_Client`（260 条，34 字段） | `clients` | `migrate.sh --client-data` | （字段映射见 V36__client.sql） |
| **供应商分类** | ✅ 已实现 | `SystemItem` (ItemclassID=3，15 扁平根) | `supplier_categories` | `migrate.sh --supplier` | [08-老库溯源](08-供应商资料-老库溯源.md) · [09-新库与迁移](09-供应商资料-新库与迁移.md) |
| **供应商主档** | ✅ 已实现 | `B_Provider`（386 条，29 字段） | `suppliers` | `migrate.sh --supplier-data` | （字段映射见 V38__supplier.sql） |
| **币种 / 仓库** | ✅ 已实现 | `B_Currency`(3) / `B_Storage`(6) | `currencies` / `warehouses` | `migrate.sh --currency-data` / `--warehouse-data` | [15-采购 §三](15-采购模块-新库与迁移.md)（归基础资料） |
| **采购管理** | ✅ 已实现 | `P_Application`/`P_Order`/`P_In`/`P_Withdraw`（主+明，十几万行） | `purchase_requests/orders/receipts/returns(+_items)` | `migrate.sh --purchase` | [14-老库溯源](14-采购模块-老库溯源.md) · [15-新库与迁移](15-采购模块-新库与迁移.md) |
| **库存（流水+余额）** | ✅ 已实现 | `StockGoods`(45万) + 9 类 `O_*` 单据 | `stock_movements` / `stock_balances` / `stock_documents(+_items)` | `migrate.sh --stock-docs` | [16-老库溯源](16-仓库管理-老库溯源.md) · [17-新库与迁移](17-仓库管理-新库与迁移.md) |
| **销售管理** | ✅ 已实现 | `S_Order`(10653)/`S_Out`(12124)/`S_OtherOut`(1558)/`S_Withdraw`(221)（在用）+`S_Quote`(0) | `sales_orders/shipments/other_shipments/returns(+_items)` | `migrate.sh --sales` | [18-总路线图](18-业务四模块-总路线图.md) · [19-老库溯源](19-销售管理-老库溯源.md) · [20-新库与迁移](20-销售管理-新库与迁移.md) |
| **委外管理** | ✅ 已实现 | `E_` 前缀（**确认是委外**）：`E_In`(10732)/`E_SOut`(10627)/`E_WithDraw`/`E_SWithDraw`/`E_SWaste` | `subcontract_*`（8 单据） | `migrate.sh --subcontract` | [18] · [21-老库溯源](21-委外管理-老库溯源.md) · [22-新库与迁移](22-委外管理-新库与迁移.md) |
| **生产管理** | ✅ 已实现 | `F_Plan`(7235)+Item(73388) / **`F_PlanCostItem`(1359892)** / `F_DateReport`(0) | `production_plans(+items/+costs 按年分区)` / `production_daily_reports` | `migrate.sh --production` | [18] · [23-老库溯源](23-生产管理-老库溯源.md) · [24-新库与迁移](24-生产管理-新库与迁移.md) |
| **钱流管理** | ✅ 已实现 | `M_Get`/`M_In`(42489)/`M_Paid`/`M_Out`(44525)/`M_DPaid`/`M_OGet`/`M_Acc`(27)/`M_Style`(124)/`M_AllCheck` | `finance_receipts/payments/expenses/...(+_lines)` + 统一 `ar_ap_ledger`(87014) + `accounts`/`payment_styles` 主档 | `migrate.sh --finance` | [18] · [25-老库溯源](25-钱流管理-老库溯源.md) · [26-新库与迁移](26-钱流管理-新库与迁移.md) |
| 工资 / 报销 / 检测 | ⏳ 待做 | `W_*` / `B_*` / `C_*` | 待 | 待 | — |

> 模块对应的完整老库结构见 [01-YTDQ老库总览](01-YTDQ老库总览.md)。

---

## ⚙️ 老库连接配置

```yaml
app:
  legacy:
    enabled: ${UTEN_LEGACY_ENABLED:false}     # 默认关，迁移时显式开
    datasource-url: ${UTEN_LEGACY_DB_URL:jdbc:sqlserver://(localdb)\MSSQLLocalDB;databaseName=YTDQ_2023;encrypt=false}
    datasource-username: ${UTEN_LEGACY_DB_USER:}     # LocalDB 集成认证留空
    datasource-password: ${UTEN_LEGACY_DB_PASSWORD:}
```

- **dev**：指向本机 LocalDB（集成认证，账号密码留空）。
- **prod**：换生产 SQL Server 实例的账号密码（profile 隔离，见 `application-prod.yml`）。

---

## 📁 目录结构

```
docs/数据迁移/                          ← 本文件夹（迁移执行文档）
├─ README.md                            ← 你在这（主索引 / 一键迁移）
├─ 01-YTDQ老库总览.md                   ← 老库整体结构（196 表/168 视图/91 触发器/模块前缀）
├─ 02-货品分类-老库溯源.md              ← 货品分类在老库的存储 + 数据坑
└─ 03-货品分类-新库与迁移.md            ← 新库表设计 + 迁移用法 + 校验

server/src/main/java/com/uten/imp/legacy/       ← 迁移代码（Java，Maven 编译）
├─ config/LegacyProperties.java                 （老库连接配置）
├─ reader/
│  ├─ LegacyCategoryRow.java
│  ├─ LegacyCategorySource.java                 （接口：dev CSV / prod MSSQL 两实现）
│  ├─ LegacyCategoryCsvSource.java              （dev：按 itemClassId 选 goods=1/client=2/supplier=3/mould=18 CSV）
│  └─ LegacySystemItemReader.java               （prod：按需连 MSSQL 读 SystemItem）
├─ migration/
│  ├─ LegacyMigrationOrchestrator.java   ★ 一键迁移总入口（migrateAll）
│  ├─ MaterialCategoryMigrator.java             （货品分类，ItemclassID=1）
│  ├─ ClientCategoryMigrator.java               （客户分类，ItemclassID=2）
│  ├─ SupplierCategoryMigrator.java             （供应商分类，ItemclassID=3）
│  └─ MouldCategoryMigrator.java                （模具分类，ItemclassID=18）
└─ web/LegacyMigrationController.java           （REST 端点：/all、/material-category、/client-category、/supplier-category、/mould-category）

server/legacy_migration/                        ← shell 离线迁移（不依赖 server）
├─ migrate.sh                                   （一键：--goods/--mould/--client/--supplier 各带 -data，--all 全量）
├─ migrate_goods.sql / migrate_goods_data.sql   （货品分类 / 主档）
├─ migrate_mould.sql / migrate_mould_data.sql   （模具分类 / 主档）
├─ migrate_client.sql / migrate_client_data.sql （客户分类[递归CTE] / 主档）
├─ migrate_supplier.sql / migrate_supplier_data.sql （供应商分类[扁平根] / 主档）
├─ migrate_color.sql / migrate_unit.sql        （颜色 / 基本单位 主档[扁平，无分类]）
├─ export_legacy.ps1                            （老库→UTF-8 CSV；含 RFC4180 管道符转义，见下）
└─ data/                                        ← 离线 CSV（goods/mould/client/supplier 分类+主档 + color/unit，未进 git）

server/src/main/resources/legacy-migration/     ← dev Java 路径读的 classpath CSV（分类树快照）
├─ goods_categories.csv
├─ client_categories.csv
├─ supplier_categories.csv
└─ mould_categories.csv
```

---

## ➕ 加新模块（以后每给一批数据，按此走）

1. **探源**：在老库定位该模块数据（表 / 字段 / 树结构 / 数据坑），写一份 `0X-模块名-老库溯源.md` 放本文件夹。
2. **建新库表**：Flyway migration（仿 `V31__material_category.sql`）。
3. **写 Migrator**：仿 `MaterialCategoryMigrator`（读老库 → 拓扑序 → 按 `legacy_id` 幂等 upsert → 重算层级 → path 交触发器 → 孤儿挂虚拟根）。
4. **注册**：在 `LegacyMigrationOrchestrator.migrateAll()` 加一行 `run("模块名", xxxMigrator::migrate, ...)`。
5. **登记**：在本 README「模块清单」表加一行。
6. **端点**（可选）：单模块 `POST /api/admin/legacy-migration/<module>`。

---

## ✅ 校验

每个模块迁移后对账（详见各模块文档「校验」段）：总数一致、主键（`legacy_id`）覆盖、抽样字段比对、树路径/深度正确。

---

**最后更新**：2026-07-26 · **已实现模块**：货品/模具/客户/供应商（分类+主档）+ 颜色/单位/币种/仓库 + 采购（4 单据）+ 库存（流水+余额+仓库 9 单据）+ **销售/委外/生产/钱流（4 业务模块，全链路打通：DDL V50-V63 + 数据 100% 迁移 + Java 后端 + Flutter 前端 + e2e 验证 + UI 屏幕利用率优化）** —— 见 [18-总路线图](18-业务四模块-总路线图.md) · [27-DDL契约](27-DDL一致性契约.md) · [28-Java契约](28-Java后端契约.md) · [29-后续TODO路线图](29-后续优化与待办路线图.md) · [30-UI优化方案](30-UI屏幕利用率优化方案.md)
