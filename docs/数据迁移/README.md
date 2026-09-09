# 老库数据迁移 · 总索引
> **当前正式目录：V540/499 (2026-09-08)**。V533将附件原件身份与内部存储表示分离，V534新增服务器状态只读权限，V535使有完整合格来源的本批库存跟随实际入库仓，V536支持生产输出分仓及原单撤回，V537使业务附件真实清理完成后才允许清空测试业务，V538统一主仓公共库存安全数、保留实际子仓领料和成本。V539以独立前向迁移补齐附件删除证明，V537保留已执行文件的原校验值。V540保留停用存放仓的既有库存清出，并为自动齐套恢复记录真实系统身份。最终V540组合的迁移、恢复与全量验收以统一记录为准；专项通过不等于公司服务器已更新。
> **验证范围**：最新V532清库、旧导入SQL结构兼容、相关契约和双JAR包装复验通过，266 CLEAR/96 PRESERVE分类保留；实际服务器备份副本前向验证至V532，15,019个结构对象与全新建库一致，主档摘要保留。完整套件与后续增量证据、50万规模压力结果见[统一验收](../99-项目治理/2026-09-07-全平台本地审计与整改验收.md)。公司服务器尚未由本轮升级、清库或部署。
>
> 新增迁移均向前追加：V492 保留销售订单完整修改前后快照和财审版本；V493 退役待审收件台；V494 将委外分批守恒限定到受影响任务；V495 补根委外直属物料归属；V496 补委外通知批次追加式冲销；V497 为未全通知前置任务建立热集合部分索引；V498 防止货品已有数量业务后改变基本单位。历史已审核订单、库存及账务记录不重写。

| 说明 | 迁移 | 本次变化 |
| --- | --- | --- |
| [108](108-V492销售订单完整修改与财务版本复核.md) | V492 | 销售完整修改事实账、财审版本及清空策略同步 |
| [109](109-V493待审收件台退役.md) | V493 | 停用旧收件台权限及页面权限面，旧链接回工作台 |
| [110](110-V494委外分批通知守恒与并发.md) | V494 | 单任务守恒与分批并发校验 |
| [111](111-V495根委外前置自制物料归属.md) | V495 | 根委外使用原树直属物料，不重复展开子件 |
| [112](112-V496委外通知冲销与前置产出反向.md) | V496 | 已完整解除下游的通知批次可冲销，恢复前置产出反向资格 |
| [113](113-V497委外待生产任务分页索引.md) | V497 | 未完成前置任务与正式委外业务统一分页，历史任务不进入热查询 |
| [114](114-V498货品数量单位生命周期守卫.md) | V498 | 货品数量基准使用后固定，实际归一化与单位编辑互斥 |
| [115](115-V499已结案订单的历史预收反向.md) | V499 | 历史预收合法反向不要求原订单重新开放，新登记/绑定/审批门禁保留 |
| [116](116-V500实际平均库存价值核心.md) | V500 | 独立实际平均价值引擎、原出库退回及后补传播；后续业务接线和边界见126/127 |
| [117](117-V501全局编号与前缀检索排序规则索引.md) | V501 | 修复 C 排序规则参数无法使用默认规则索引导致的历史全扫描 |
| [118](118-V502委外目标件基本量与冻结换算率.md) | V502 | 委外目标件统一基本量，保留已执行历史换算事实 |
| [119](119-V503批准后改量的来源份额与生产挂接对账.md) | V503 | 财审改量时精确同步原申请来源及生产挂接份额 |
| [120](120-V504价值与来源改量事实清空策略.md) | V504 | 新增事实表与业务清空策略对应 |
| [121](121-V505真实恢复库结构收敛.md) | V505 | 实际恢复库的触发器、索引及默认值差异前向收敛 |
| [122](122-V506受控库存开账与历史余额待核对.md) | V506 | 实际成本开账与零库存历史残额分开核对 |
| [123](123-V507退货反向与委外返修数量守恒.md) | V507 | 退货反向容量及委外返修不重复耗料 |
| [124](124-V508执行段销量分摊有效容量.md) | V508 | 取消或反向的执行段释放占用，已完成产出仍计入容量 |
| [125](125-V511客户零星发货统一流程.md) | V511 | 客户直发收费/免费使用统一销售、财审、仓库及实际发货事实 |
| [126](126-V513至V526启动整合与业务守卫.md) | V513–V526 | 双币结清、实际物料流水、成本来源及银行字段整合；生产入库触发器按真实行类型分派 |
| [127](127-V527-V528采购委外收货撤回.md) | V527/V528 | 未用入库按原保管区间反向；委外先恢复同源自有材料，再撤加工费/实物产出 |
| [128](128-V529直接委外草稿准备.md) | V529 | SC-ORDER真实草稿行FK/快照、草稿内部生产、计划部门精确范围、送审/批准重核及真实出仓 |
| [129](129-V530业务审计覆盖与稳定对象来源.md) | V530/V531 | 业务事实完整审计、已知形状修复、主键身份排除INCLUDE列及未知异形拒绝；原审计与数据保留 |
| [130](130-V532销售来源UUID查询索引.md) | V532 | 按来源UUID定位往来台账，消除单张订单查询扫描50万条来源记录；业务数据与金额不变 |
| [131](131-V533内部附件存储与原件身份.md) | V533 | 内部附件原件与物理表示分离、历史后端归类、精确版本删除与已确认身份保护 |
| [132](132-V534服务器状态只读权限.md) | V534 | 系统管理新增服务器状态卡片的独立查看权限；不授予维护命令能力 |
| [133](133-V535合格来源跟随实际入库仓库.md) | V535 | 本批合格来源跟随实际入库仓，委外前置原件专属持有及原单反向 |
| [134](134-V536生产成本多实际仓与原单撤回.md) | V536 | 生产输出分实际仓，晚到费用沿真实库存与销售成本分配，原入库按来源撤回 |
| [135](135-V537业务附件清理完成证明.md) | V537 | 业务附件删除完成证明与测试清理准备，保留人事文件及原件删除证据 |
| [136](136-V538当前主仓统一预算说明.md) | V538 | 计划按主仓汇总，安全数只保留一次，领料保留实际子仓、预留及原批成本 |
| [137](137-V539已执行迁移兼容与附件证明前滚.md) | V539 | 保留已执行 V537 的原校验值，前向补齐临时版本和删除完成时间校验 |
| [138](138-V540停用仓既有库存与自动齐套恢复.md) | V540 | 禁止新选停用仓，既有库存按原仓清出；漏回调由有界系统任务按真实来源恢复 |

V532只为往来来源增加按来源类型、来源UUID、账本UUID查询的索引；不改表内数据、金额或业务规则。大数据实测发现的线性扫描及最新复验见[统一验收](../99-项目治理/2026-09-07-全平台本地审计与整改验收.md)。

## 使用本索引

本页保留当前迁移入口、首次离线导入的执行要求和模块清单，不再堆叠历次“当前版本”及旧测试数量。各版本的设计与兼容要求见对应迁移专册；实际数据库状态、最新验证和未完成事项以[统一验收记录](../99-项目治理/2026-09-07-全平台本地审计与整改验收.md)为准。旧设计不能覆盖[现行业务流程](../README.md)。

| 目的 | 代码及文档入口 |
|---|---|
| 已有ERP版本的数据库结构升级 | `server/src/main/resources/db/migration`；[现役发布运行手册](../../deploy/simple/RUNBOOK.zh-CN.md) |
| 首次导入YTDQ离线数据 | `server/legacy_migration/migrate.sh --bootstrap-all`；本页后续离线快照和Manifest要求 |
| 开发/内部测试清空业务数据 | `server/ops/reset_business_data.sql`、`BusinessDataResetService`及迁移维护的`business_data_reset()`；保留主档、权限与审计，不等同于旧库业务导入 |
| 当前目录兼容检查 | `server/src/test/java/com/uten/imp/migration/MigrationRehearsalSupport.java`、`LegacyBootstrapSchemaCompatibilityPostgresTest`、`BusinessDataResetServicePostgresTest` |

## 🔐 目标库迁移 authority 与停点

目标库升级/迁移按 [ADR-060](../99-决策记录-ADR/ADR-060-单维护者简化发布链与旧发布链退役.md) 现役链执行（tag → simple-release → OSS 签名制品 → 服务器 updater 拉取验签 → migrator），操作步骤见 [新库上线与首装操作指引](../99-项目治理/2026-09-01-新库上线与首装操作指引.md) 与 [deploy/simple/RUNBOOK](../../deploy/simple/RUNBOOK.zh-CN.md)；当前源码候选目录头见本页顶部横幅，目录数字本身不能授权目标库升级。不变的底线：

1. **制品同源**：主 JAR、migration-only JAR 与 Flyway checksum 必须出自同一签名制品（以 OSS `LATEST.txt` 指向的版本为准）。
2. **核对已应用字节不可变**：live `flyway_schema_history` 中每个已应用 version/script/checksum 必须与制品完全一致；任一 mismatch、失败行、重复版本、未来版本或未知 repeatable 立即 **NO-GO**。禁止 `flyway repair`、手工改 history、修改/重命名已应用 SQL 或用旧 JAR 回滚覆盖。
3. **先备份后升级**：升级窗口前保留经验证可恢复的备份。
4. **正式窗口单版本切换**：停写、排空旧实例后只运行同一制品的 migrator；应用运行账号不持 DDL 权限。迁移、live history 校验、readiness 和业务对账全部通过前，ERP/Nginx 入口保持关闭，禁止新旧 JAR 滚动并存。
5. **失败只前向或恢复**：失败时保留证据并保持入口关闭，只能新增更高版本的前向修复，或恢复与旧版本完全一致且已演练的备份；不得删约束、禁触发器、伪造回填或继续带病启动。

（旧链的冻结签名 lineage、H01–H12 带外 authority、GITHUB_SIGNING/OOB 仪式已随 ADR-060 退役，相关 deploy/ 文档保留仅作参考。）
上述步骤是 Flyway schema 升级；下面的 legacy bootstrap 是另一条首次离线业务数据导入链。两者分别记录来源、执行授权、对账和结果凭据，不能用“Flyway成功”代替旧业务数据导入，也不能用`bootstrap-all`代替完整schema history。导入映射版本和数据库迁移版本属于不同标识；本地兼容检查采用`MigrationRehearsalSupport`声明的当前目录，实际目标库数据导入与对账仍须单独留证。


## 🚨 执行边界：只有首次离线 bootstrap，不存在运行时增量迁移

当前能力分为正式离线链和本地开发样例，二者不能混称“一键迁移”：

| 入口 | 覆盖范围 | 证据边界 | 可用于切流后追平 |
|---|---|---|---|
| `server/legacy_migration/migrate.sh --bootstrap-all` | 主档及采购、库存、销售、委外、生产、钱流等首次导入 | 导入协调器仍冻结V426/388及`bootstrap-v10-v426`。较新结构上的SQL兼容检查不授权直接在新库执行该协调器；真实导入、manifest与对账另行验收 | **不可以** |
| `/api/admin/dev/legacy-category-seed/*` | 四棵 classpath 分类样例 | 仅 `dev` profile 的页面/分类树调试 | **不可以** |

运行中 ERP 不包含 SQL Server 驱动或老库 DataSource，也没有 `/api/admin/legacy-migration/all`。
Shell 会拒绝无目标、未知目标和多目标调用，并要求破坏性确认。它保持 FK、审计触发器和 UUID
注册身份有效，以 FK 顺序 `DELETE`/重建；禁止 `TRUNCATE`、`CASCADE` 和禁用约束。

单模块命令只用于隔离演练或故障定位：

```bash
bash server/legacy_migration/migrate.sh --stock-docs --confirm-destructive
bash server/legacy_migration/migrate.sh --subcontract --confirm-destructive
```

完整引导只允许在可清空的新库/演练库执行：

```bash
bash server/legacy_migration/migrate.sh --bootstrap-all --confirm-destructive
```

> **禁止**把 dev 分类样例当生产迁移，禁止把破坏性 Shell 脚本用于已切流模块，禁止用多目标命令。
> 当前仅首次全量 bootstrap 具备受审输入绑定和自动结构对账；增量、dry-run、统一 quarantine 与可重复回滚尚未交付，不能把首次引导脚本冒充持续迁移体系。
> 销售是顺序依赖的典型：`--sales` 只导入单据并保留 `seller_legacy_id`，HR 员工
> `legacy_id` 可用后还必须执行单独的 `--sales-owner` 回填。推荐只用 `--bootstrap-all` 的内置顺序；
> 不得把“销售表有数据”误判为 owner 归属已经完成。

> **⚠️ 数据坑（已修，迁其他含地址/备注的表时复用）**：老库 varchar 字段（地址、收货地址、备注）
> 可能含管道符 `|`。`export_legacy.ps1` 的 `Export-Query` 已做 RFC4180 引号转义（字段含
> 分隔符/引号/换行则 `"..."` 包裹、内部 `"`→`""`），配合 COPY `FORMAT csv` 正确还原。
> 不转义会 `missing data for column X`（客户主档首跑即踩）。

---


离线 bootstrap 目标冻结为 V426/388，使用映射标识 `bootstrap-v10-v426` 和受保护 388 行 manifest，实际目标库的版本、脚本名、校验值必须与该 manifest 精确一致。V426 不授权跨越或执行尚未获准的破坏性 V425。该约束属于旧系统首次导入，不是当前ERP升级或业务清库的目录头；V531结构兼容专项不代表整套旧导入协调器已在V531执行。

## 📦 首次旧库导入的模块清单

> 表中每个 `migrate.sh` 目标均是脚本真实支持的单目标 flag；实际执行必须再传 `--confirm-destructive`
> （或数据库名绑定的 `UTEN_CONFIRM_DESTRUCTIVE_MIGRATION`）。各目标必须分开调用，只有显式
> `--bootstrap-all` 会按内置依赖顺序执行全量引导。

| 模块 | 状态 | 老库来源 | 新库表 | 迁移代码 | 文档 |
|---|---|---|---|---|---|
| **货品分类** | ✅ 已实现 | `SystemItem` (ItemclassID=1) | `material_categories` | `migrate.sh --goods` | [02-老库溯源](02-货品分类-老库溯源.md) · [03-新库与迁移](03-货品分类-新库与迁移.md) |
| **货品主档** | ✅ 已实现 | `B_Goods`（35750 条，全 78 字段，image 留空） | `goods` | `migrate.sh --goods-data` | （字段映射见 V32__goods.sql） |
| **货品组装（BOM）+ 成本预算** | ⛔ 待业务处置拒绝行 | `B_BomItem`（218,820 行；正确孤儿 20,798）/ 成本列随主档 | `goods_bom_items`（有效源迁移 198,022；另有新系统手工行） | `migrate.sh --goods-bom --confirm-destructive` | [31-组装BOM与成本预算](31-货品组装BOM与成本预算.md)；V181 隔离 81 条误接占位边，计数守恒不等于零数据丢失 |
| **即时库存** | ✅ 已实现 | `View_IOStockGoods` 口径：`StockGoods.FactQTY/FactWeight` + `B_Goods.Paper/CTotal` + `View_ProductMore`（F_PlanItem） | `stock_balances`（**V80 增 weight**；余额含重量 1,288 行） | `migrate.sh --stock-docs`（重跑即补重量） | [32-即时库存](32-即时库存.md) |
| **模具分类** | ✅ 已实现 | `SystemItem` (ItemclassID=18，65 个扁平业务根) | `mould_categories`（V272 候选目标 66 根：65 业务根 + 1 系统“未分类”根） | `migrate.sh --mould` | [04-老库溯源](04-模具资料-老库溯源.md) · [05-新库与迁移](05-模具资料-新库与迁移.md) |
| **模具主档** | ✅ 已实现 | `B_Mould`（1605 条，12 字段；19 条源分类悬空） | `moulds`（V272 候选目标：系统根 19、`category_id NULL` 0） | `migrate.sh --mould-data` | （字段映射见 V34__mould.sql） |
| **颜色** | ✅ 已实现 | `B_Color`（151 条，**实测扁平**非树；`B_Goods.MColorID` 引用） | `colors` | `migrate.sh --color-data` | [10-老库溯源](10-颜色资料-老库溯源.md) · [11-新库与迁移](11-颜色资料-新库与迁移.md) |
| **基本单位** | ✅ 已实现 | `B_Unit`（66 条，扁平，与 B_Color 同构；`B_Goods.UnitID` 引用） | `units` | `migrate.sh --unit-data` | [12-老库溯源](12-基本单位-老库溯源.md) · [13-新库与迁移](13-基本单位-新库与迁移.md) |
| 模具 | ✅ 见上 | — | — | — | （已拆为「模具分类 + 模具主档」两行） |
| 员工 | ✅ 正式名录 141 人已录入（2026-08-05）；转正日期已按入职日期回填（V210/ADR-021）；老库 stub 融合键约定保留 | `B_Worker` + 《职工信息表.xls》 | `employees` / `employee_sensitive` / `positions` / `employment_history` | `build_hr_roster.py` → `migrate.sh --hr-cleanup --hr-roster --confirm-destructive`；老库 stub：`--hr-workers` | [34-人事老库迁移](34-人事老库迁移.md) · [53-人事正式名录迁移](53-人事正式名录迁移.md) · [74-转正日期回填与员工车辆联系方式](74-转正日期回填与员工车辆联系方式.md) |
| **客户分类** | ✅ 已实现 | `SystemItem` (ItemclassID=2，10 个业务根/40 个业务节点/最大 level 2) | `client_categories`（V272 候选目标 11 根/41 节点，含系统“未分类”根） | `migrate.sh --client` | [06-老库溯源](06-客户资料-老库溯源.md) · [07-新库与迁移](07-客户资料-新库与迁移.md) |
| **客户主档** | ✅ 已实现 | `B_Client`（260 条，34 字段；6 条未分组） | `clients`（V272 候选目标：系统根 6、`category_id NULL` 0；官网/财务后续兜底同根） | `migrate.sh --client-data` | （字段映射见 V36__client.sql） |
| **供应商分类** | ✅ 已实现 | `SystemItem` (ItemclassID=3，15 个扁平业务根) | `supplier_categories`（V272 候选目标 16 根，含系统“未分类”根） | `migrate.sh --supplier` | [08-老库溯源](08-供应商资料-老库溯源.md) · [09-新库与迁移](09-供应商资料-新库与迁移.md) |
| **供应商主档** | ✅ 已实现 | `B_Provider`（386 条，29 字段，源端全有业务分类） | `suppliers`（V272 候选令 `category_id NULL` 为 0；财务占位绑定系统根） | `migrate.sh --supplier-data` | （字段映射见 V38__supplier.sql） |
| **币种 / 仓库** | ✅ 已实现 | `B_Currency`(3) / `B_Storage`(6) | `currencies` / `warehouses` | `migrate.sh --currency-data` / `--warehouse-data` | [15-采购 §三](15-采购模块-新库与迁移.md)（归基础资料） |
| **采购管理** | ✅ 已实现（单位歧义行待治理） | `P_Application`/`P_Order`/`P_In`/`P_Withdraw`（主+明，十几万行） | `purchase_requests/orders/receipts/returns(+_items)` + V65 报表列 + V168 历史单位安全规范化 | `migrate.sh --purchase`（`migrate_purchase.sql`） | [14-老库溯源](14-采购模块-老库溯源.md) · [15-新库与迁移](15-采购模块-新库与迁移.md)（**9 报表 + V65 迁移补全 + V168 单位治理**） |
| **库存（流水+余额）+ 仓库报表** | ✅ 已实现 | `StockGoods`(45万) + 9 类 `O_*` 单据 | `stock_movements` / `stock_balances` / `stock_documents(+_items)` | `migrate.sh --stock-docs`（含人员 *_legacy_id + B_Worker stub + 末尾刷 MV） | [16-老库溯源](16-仓库管理-老库溯源.md) · [17-新库与迁移](17-仓库管理-新库与迁移.md) · [50-盘点修正与历史处理](50-仓库盘点修正与历史单据处理.md) · **14 张仓库报表**（V67：7 单据 × 明细/汇总，`/api/stock/reports/{docType}/{detail|summary}`，明细已含「库位号」列） |
| **货架库位（目视化清单）** | 🟡 源码候选；挂牌数据待仓库整理（迁移 SQL 已在开发库实弹演练：成功/幂等/拒绝三路径全过） | **无老库源**（现场挂牌；老库 `B_Goods.StockPlace` 为无关残值，`StockLabel`/`StockSLabel` 为数量快照非库位，均不迁） | `goods.stock_place`（V32 已有列） | 人工整理 `data/shelf_labels.csv` → `migrate.sh --shelf-labels`（不进 bootstrap-all；同键与跨键重复货品均显式拒绝） | [17 §十二](17-仓库管理-新库与迁移.md) · [货架目视化清单页](../03-页面/货架目视化清单页.md) |
| **销售管理** | 🟡 单据导入已实现；V187–V189 与 V220 已包含在公司目标库 V238，历史对账、对象授权和岗位 UAT 待最终验收 | `S_Order`(10653)/`S_Out`(12124)/`S_OtherOut`(1558)/`S_Withdraw`(221)（在用）+`S_Quote`(0) | `sales_orders/shipments/other_shipments/returns(+_items)` + V187 发运/仓库字段 + V188 仓库事件 + V189 退货质量冻结 + V220 客户处置 | `--sales` 导单；员工迁入后 `--sales-owner` 回填（完整流程用 `--bootstrap-all`） | [18-总路线图](18-业务四模块-总路线图.md) · [20-新库与迁移](20-销售管理-新库与迁移.md) · [39-owner 迁移/授权](39-销售单据归属授权.md)；历史不补造确认、拣货事件、质检或客户处置结论 |
| **委外管理** | ⛔ 历史发料待重迁验收；V436 新流为源码候选 | `E_` 前缀：`E_In`/`E_SOut`/`E_WithDraw`/`E_SWithDraw`/`E_SWaste` | `subcontract_*`（8 单据） | `migrate.sh --subcontract --confirm-destructive` | 现有历史库 49,889 发料明细数量口径失真；须用修正导出重迁并复核 [22](22-委外管理-新库与迁移.md) / [42](42-财务对账单自动生成.md)。新单目标件出仓/前置自制只认 [66](66-委外目标件出仓与前置自制准备.md) / [ADR-059](../99-决策记录-ADR/ADR-059-委外目标件出仓与前置自制准备.md) |
| **生产管理** | ✅ 已实现 | `F_Plan`(7235)+Item(73388) / **`F_PlanCostItem`(1359892)** / `F_DateReport`(0) | `production_plans(+items/+costs 按年分区)` / `production_daily_reports` | `migrate.sh --production` | [18] · [23-老库溯源](23-生产管理-老库溯源.md) · [24-新库与迁移](24-生产管理-新库与迁移.md) |
| **钱流管理** | 🟡 功能主体已导入，财务验收未关闭 | `M_Get`/`M_In`/`M_Paid`/`M_Out`/`M_DPaid`/`M_OGet`/`M_Acc`/`M_Style`/`M_AllCheck` | `finance_receipts/payments/expenses/...(+_lines)` + `ar_ap_ledger` + 主档 | `migrate.sh --finance --confirm-destructive` | 总账开账、账户期初、材料领用结转和 AR/AP 对账必须由财务签字；见 [26](26-钱流管理-新库与迁移.md) / [44](44-总账子系统.md) |
| **资产与长期待摊专业子账** | 🟡 新功能安全骨架；完整生产 **NO-GO** | **无老库业务数据，本次不迁移** | V123/V140 主档兼容升级 + V183 类别、账簿、计划、审批、事件、期间、不可变批次/明细 | **无 legacy flag；禁止用破坏性脚本或手工 SQL 回填** | 只能从经财务批准的当前期间初始化；历史期初/累计额/剩余期限能力未交付。核心落账门禁默认关闭，见 [51](51-资产与待摊专业化全链路.md) / [ADR-018](../99-决策记录-ADR/ADR-018-资产与待摊专业子账及不可变过账.md) / [验收报告](../99-项目治理/2026-08-01-资产与待摊全链路实现与验收报告.md) |
| 工资 / 员工报销 / 检测 | ⏳ 待做 | 待最终探源 | 待 | 待 | V133 已建工资/员工报销新域，但老库源表、映射、导出、导入、reject 和对账尚未实现；一般费用单不是员工报销 |

> 模块对应的完整老库结构见 [01-YTDQ老库总览](01-YTDQ老库总览.md)。

---

## ⚙️ 老库连接与一致性要求

ERP 运行时不包含 SQL Server 驱动、生产迁移 DataSource 或生产迁移 HTTP 端点。`app.legacy.enabled` 是已退役通道的关闭哨兵，内部测试环境固定为 `false`。正式源读取只允许由 `export_legacy.ps1` 在受审运维会话中通过私有 `LEGACY_DB_CONNECTION_STRING` 连接离线恢复库。

- **dev**：指向本机 LocalDB（集成认证，账号密码留空）。
- **上线演练/最终切换**：只连接停写后恢复出的离线备份、只读副本或数据库级一致性快照。
- **禁止**让 CSV 导出直接扫描仍在持续写入的生产 SQL Server。全量导出只接受停写后恢复的离线备份，并在一个 `Serializable` 事务中读取全部表。
- `export_legacy.ps1` 可用 `LEGACY_DB_CONNECTION_STRING` 指向离线恢复库；连接串不得写入文档、manifest 或 Git。

---

## 🧾 导出 Manifest 与离线快照

推荐顺序：

```powershell
# 1. 停止老系统写入，取得并恢复离线备份/一致性快照
# 2. 通过私有环境绑定 CMDB 源身份、离线备份摘要和批准窗口
$env:LEGACY_SOURCE_AUTHORITY_ID='<CMDB_ID>'
$env:LEGACY_SOURCE_BACKUP_SHA256='<64_HEX_SHA256>'
$env:LEGACY_EXPORT_APPROVAL_REFERENCE='<APPROVAL_REFERENCE>'

# 3. 从恢复库导出全部 CSV
powershell -ExecutionPolicy Bypass `
  -File server/legacy_migration/export_legacy.ps1 All

# 4. 核验 export_manifest.json + export_manifest.sha256；迁移入口也会自动校验
# 5. 在可清空目标库执行破坏性引导
bash server/legacy_migration/migrate.sh --bootstrap-all --confirm-destructive
```

`export_manifest.json`（formatVersion 3）记录：

- 导出目标、UTC 时间、非秘密源 authority、离线备份 SHA-256 和批准引用；
- 每个文件的行数、字节数和 SHA-256；
- `consistency = serializable-read-transaction` 与 `offlineBackupRequired = true`；
- 导出脚本 SHA、仓库 commit，以及 `export_manifest.sha256` 自身的 SHA；
- 不记录 server、database、连接串或凭据。

`migrate.sh` 会自动：

- 拒绝 JSON/sha256 清单缺失、两份清单不属于同一导出、目标 CSV 未登记或内容被篡改；
- 拒绝 manifest 提交与当前 importer/Flyway 提交不同，或 scoped 源码仍有未提交字节；
- 将 run 的两个 manifest 指纹、迁移脚本指纹、代码 commit 和映射版本写入
  `legacy_migration_runs`；
- 将本次实际消费的 manifest、CSV、Shell、SQL、Flyway 清单及其 SHA-256/字节数写入 `legacy_migration_run_files`；
- 对全量 bootstrap 固定写入 20 项核心行数、CSV 消费、系统根、UUID 关系、结算方式、仓库映射、活动 BOM、reject 与历史 anchor 结构化证据；任一强制项失败则 run 失败。

Manifest 证明受审导出器在一个串行化事务中捕获了绑定到离线备份的文件集合，但不证明恢复可用或业务口径正确。最终迁移包还必须保存停写时间、恢复演练、目标 Flyway 版本、执行人、run_id、金额/数量/来源谱系报告和业务/财务签字。

---

## 🔁 当前能力边界与未来增量验收

| 能力 | 当前状态 | 上线要求 |
|---|---|---|
| 四棵分类树 Java upsert | 已有 | 补源水位、删除语义、冲突与回滚测试 |
| Shell 首次引导 | 已有破坏性脚本；输入、提交、实际消费文件和 20 项自动结构对账可追溯 | 仅在可清空库执行；必须用同一离线备份、manifest 和 run_id |
| 全模块增量追平 | **未实现** | 按稳定业务键/watermark/CDC 实现，不得 TRUNCATE |
| dry-run / reject / quarantine | V134 已有结构化 reject 表，但各模块尚未统一写入 | 所有丢弃/修复/存根均可追踪、可复核、可重放 |
| checkpoint / resume / rollback | V134 已有未来 checkpoint 表；当前 bootstrap 不推进，增量 loader 未实现 | 中断可继续，切换失败可回退且不丢新写 |
| 自动对账 | 全量 bootstrap 已固定写入核心源行数、CSV 消费和 UUID/结构不变量；金额、数量、状态、来源谱系仍需模块报告与人工签字 | 完整实现 `源数 = 目标数 + 批准拒绝数`、金额/数量/hash/孤儿与状态分布，并纳入同一 run |

未来可重复迁移只有同时满足以下门禁才算完成：

- [ ] 映射规则版本化，脚本、Flyway、源快照和目标版本可关联；
- [ ] 全量、增量、dry-run、断点续跑、幂等重跑和回滚均有命令与测试；
- [ ] 每模块显式源水位/时间窗/业务键，定义新增、更新、删除和冲突策略；
- [ ] 先进入 staging，拒绝行进入 quarantine，不允许只打印“跳过 N 行”后丢弃；
- [ ] 自动校验 `源数 = 目标数 + 批准拒绝数`，并核对关键金额/数量/状态/hash；
- [ ] 迁移运行有互斥锁、目标库保护、维护窗口、run_id、日志和失败告警；
- [ ] 使用生产同构数据至少完成两次全流程演练，记录耗时、停机窗口和恢复时间；
- [ ] 最终切流执行停写 → 增量追平 → 对账 → 业务/财务签字 → 切换；失败按预案回滚。

---

## 📁 目录结构

```
docs/数据迁移/                          ← 本文件夹（迁移执行文档）
├─ README.md                            ← 你在这（主索引 / 一键迁移）
├─ 01-YTDQ老库总览.md                   ← 老库整体结构（196 表/168 视图/91 触发器/模块前缀）
├─ 02-货品分类-老库溯源.md              ← 货品分类在老库的存储 + 数据坑
└─ 03-货品分类-新库与迁移.md            ← 新库表设计 + 迁移用法 + 校验

server/src/main/java/com/uten/imp/legacy/       ← 仅 dev profile 的分类样例种子
├─ reader/
│  ├─ LegacyCategoryRow.java
│  ├─ LegacyCategorySource.java
│  └─ LegacyCategoryCsvSource.java              （dev：按 itemClassId 读取四份 classpath 样例）
├─ migration/
│  ├─ MaterialCategoryMigrator.java             （货品分类，ItemclassID=1）
│  ├─ ClientCategoryMigrator.java               （客户分类，ItemclassID=2）
│  ├─ SupplierCategoryMigrator.java             （供应商分类，ItemclassID=3）
│  └─ MouldCategoryMigrator.java                （模具分类，ItemclassID=18）
└─ web/LegacyMigrationController.java           （仅 dev：/api/admin/dev/legacy-category-seed/*）

server/legacy_migration/                        ← shell 离线破坏性引导（不依赖 server）
├─ migrate.sh                                   （一次一个目标；--bootstrap-all 才执行全量依赖链；强制破坏性确认）
├─ migrate_reconciliation.sql                   （全量导入 20 项结构化对账；失败阻断候选）
├─ migrate_goods.sql / migrate_goods_data.sql   （货品分类 / 主档）
├─ migrate_mould.sql / migrate_mould_data.sql   （模具分类 / 主档）
├─ migrate_client.sql / migrate_client_data.sql （客户分类[递归CTE] / 主档）
├─ migrate_supplier.sql / migrate_supplier_data.sql （供应商分类[扁平根] / 主档）
├─ migrate_color.sql / migrate_unit.sql        （颜色 / 基本单位 主档[扁平，无分类]）
├─ migrate_purchase.sql                         （采购四类单据；单位确定性回填 + 歧义行诊断）
├─ export_legacy.ps1                            （离线备份→UTF-8 CSV；串行化事务输出 v3 manifest + sha256 清单）
└─ data/                                        ← 离线 CSV + export_manifest.json + export_manifest.sha256（敏感迁移包，不进 git，受控保管）

server/src/main/resources/legacy-migration/     ← dev Java 路径读的 classpath CSV（分类树快照）
├─ goods_categories.csv
├─ client_categories.csv
├─ supplier_categories.csv
└─ mould_categories.csv
```

---

## ➕ 新增迁移模块

1. **探源与批准**：在离线恢复源库定位表、字段、字符集、关系和异常行，记录源库 authority、备份摘要与双人批准引用。
2. **前向结构**：需要新结构时只新增不可变 Flyway migration；已应用文件不得修改或 `repair`。
3. **受审导出**：把查询加入 `export_legacy.ps1` 的固定目标 inventory，使 CSV、行数和 SHA-256 同时进入 v3 manifest。
4. **离线导入**：新增 `migrate_*.sql`，保持 FK/审计触发器开启，明确 UUID 真源、历史快照和 reject 口径。
5. **编排与证据**：把脚本加入 `migrate.sh` 的固定依赖顺序、逐文件摘要和 reconciliation；单模块成功不能替代完整对账。
6. **验证与文档**：增加静态合同、空库 Flyway、真实 PostgreSQL 正负例和业务对账说明，再更新本页模块清单。

如确需本地 UI 样例，可另加 `dev` profile 的 classpath seed；不得增加生产 SQL Server reader、运行时迁移端点或可切换的老库凭据配置。

---

## ✅ 校验

以下按引入版本保留历史数据兼容要求；其中当时的候选状态、版本数量和流程描述不作为当前运行状态，现行操作统一查业务SOP。

每个模块迁移后必须对账（详见各模块文档「校验」段）：总数恒等、主键（`legacy_id`）覆盖、
关键金额/数量/状态汇总、外键/孤儿、抽样字段与业务单据。被跳过的数据必须进入 reject/quarantine
并由业务批准处置；“脚本成功”或“源数−跳过数=目标数”不等于迁移验收通过。

首次 `--bootstrap-all` 会写入 20 项固定结构对账，覆盖核心分类/主档行数、CSV inventory、系统根
authority、当前 UUID 关系、客户默认结算方式、仓库/车间映射、活动 BOM 端点和 rejects。必须得到
20 项 mandatory、0 项 failed 且 `legacy_migration_runs.reconciliation_status = PASSED`；单模块执行保持
`NOT_RUN`。这些只是结构证据，仍须完成金额、数量、状态、来源谱系、抽样单据和岗位签收，才能形成
目标环境迁移验收。

### BOM 占位货品专项门禁（V181）

- 业务历史表可为 NOT NULL FK 保留 `goods.auto_created=true` 占位，它只代表“原货品主档已不存在”的身份锚；
  不得进入当前货品选择、活动 BOM、MRP 或成本重算。
- `--goods-bom` 的父件和组件均须满足 `legacy_id` 命中、未删除、非 `auto_created`；末尾硬断言活动
  BOM 占位端点为 0。先迁业务 stub 或先迁 BOM 都必须得到相同结果。
- 旧口径误把 81 条 stub 支撑的孤儿边算作有效：正确对账为
  `218,820 = 198,022 有效源行 + 20,798 拒绝行`。V181 软删错误 BOM 边，但不删除 31 个历史引用锚，
  也不批量重算 `goods.source_e`，避免改写历史预算口径。
- 若错误 BOM 已派生运营草稿，V181 仅在全量下游依赖检查为 0 时软删：本机为 2 条未领用 DRAW
  占位明细，以及 1 张仅含占位明细、未下单的 MRP 采购申请；任何已审核、已领用、已下单或有台账/
  财务/Outbox 事实的记录都会使迁移 fail-closed。历史盘点单、7 条占位货品库存余额和成本快照不动。
- **现库验证（2026-08-01）**：V181 已在 `flyway_schema_history` 成功应用，现为不可变迁移；活动 BOM
  198,025 条、活动 stub 端点 0，活动 DRAW/采购申请 stub 明细均为 0。Q7 真实第 7 项保留、虚假 7.1 已隔离；
  20,798 条源端 reject 仍需逐行治理，V181 的技术隔离不等于业务认定或生产验收完成。

### 采购单位专项门禁

采购明细的 `QTY` 是单据单位量，必须先用有效 `unit_rate` 换为货品基本单位后才能参与库存和 MRP：

- **安全修复**：源 `UnitID=0/NULL`、`COALESCE(URate,1)=1`，且货品基本单位可解析时，
  全量导入脚本 `migrate_purchase.sql` 和既有库规范化迁移
  `V168__normalize_legacy_purchase_item_units.sql` 均回填货品基本单位及换算率 1。
- **待治理**：不满足上述唯一确定条件的行不得猜测单位或换算率，保持待治理并 fail-closed；
  不能把它们当成零在途继续计算齐套。
- **MRP 阻塞范围**：只有“订货单已审核、未中止、未结案、未删除，明细未删除，且
  `GREATEST(qty-received_qty,0)>0`（源字段口径 `QTY-RQTY>0`）”的开放订货明细参与在途与单位有效性检查；历史已完成、已中止、已结案或已删除行不阻塞。
- **旧尾数处置**：若开放订货尾数已不再履约，必须由业务执行中止/结案并留痕；禁止迁移脚本仅按单据年龄
  自动关单。

2026-07-31 对 V168 做过事务内演练并已**回滚**：四类采购明细分别可安全规范化
345/394/756/39 行；开放订货单位异常 54 行中 41 行可安全修复、13 行仍待治理，
货品 `V51115` 的异常开放行由 5 行降为 0。该结果仅证明迁移可执行，**不表示正式数据库已经应用**；
正式应用状态必须以目标库 `flyway_schema_history` 和发布迁移记录为准。

### V187 销售发运与仓库作业迁移门禁

`V187__sales_shipment_policy_and_warehouse_work.sql` 是向前加法迁移，不修改 V90 预留数量、库存余额、流水、订单数量或历史审核状态：

- 历史销售订单的 `shipment_policy` 只回填 `LEGACY_UNSPECIFIED`；不得批量猜成“允许分批”或伪造客户确认。
- 历史出货按原删除/驳回/审核状态映射为 `CANCELLED/SHIPPED/REVERSED/LEGACY_PENDING`；历史 `picking_started_at/picked_at/handed_over_at` 保持空。V443 后 `LEGACY_PENDING` 只读并进入迁移异常治理，不再允许直接兼容审核。
- 新单数据库默认 `CUSTOMER_CONFIRM` / `PENDING_PICK`，应用仍必须显式走服务端状态机。
- 新权限 `sales_order:confirm_partial_shipment` 默认授销售部，`sales_shipment:warehouse-work` 默认授 PMC；上线前须按真实岗位复核，默认部门授权不等于最终职责分离签字。
- V90 `chain_status=0` 且无有效预留的旧未结订单不得自动变为可发。新建 V187 出货必须提前 fail-closed；业务须逐订单行对账库存、历史已发和旧排产后显式激活。当前没有自动批量激活脚本，禁止为“让页面可用”伪造预留。
- V187 不回写历史商业字段。新业务由应用从来源订单重建出货客户、币税/付款条件和行价格/金额；迁移不能替应用猜测或修复历史定价事实。

目标库执行前后至少对账：四类销售主表/明细行数和数量金额汇总不变；V187 新列 null/枚举分布符合历史映射；V443 后旧 `LEGACY_PENDING` 草稿只能只读留证并从当前订单来源人工重建，新单和旧草稿都不能走旧审核；无权限用户看不到动作且直接调用 403。下文“171 个迁移至 V190、真实 PG 54/54”是 2026-08-01 的历史候选证据；V187–V189 与后续 V220 在该历史验证时点已包含于当时公司目标库V238，但这仍不能替代历史全量对账、对象权限、岗位 UAT 和发布签字，销售生产门禁尚未关闭。

### V188 销售仓库事件账迁移门禁

`V188__sales_shipment_warehouse_event_ledger.sql` 只新建 `sales_shipment_warehouse_events`、索引、append-only 守卫和审计触发器，不回填历史 V187/老库出货时间线，不修改任何出货当前状态、库存、预留、订单累计或应收。

目标库应用后新事件的 `from_status/to_status/reason/actor_employee_id/occurred_at` 必须与同事务状态转换一致；UPDATE/DELETE 必须由数据库拒绝。新表初始为空是正确的历史边界，不得以“时间线看起来完整”为由批量造事件。

### V189 销售退货质量冻结迁移门禁

`V189__sales_return_quality_quarantine.sql` 只新建质量冻结当前投影、追加式处置事件和权限，不回填历史已审核退货，不修改历史库存余额或流水。历史行没有质检证据，因此禁止用脚本推断为良品、报废或返工。

目标库执行前后必须满足：`sales_returns`、`sales_return_items`、`stock_movements` 和 `stock_balances` 的历史行数/数量/金额不变；两张新质量表初始行数为 0；新退货审核后只增加冻结行而不增加库存；只有 `GOOD_RELEASE` 增加库存；事件 UPDATE/DELETE 被数据库拒绝。发生处置后整单红冲会正确阻断，但当前没有处置级复核红冲/补偿命令，此项仍为运行 NO-GO。详见 [销售退货质检冻结与处置](../07-业务链路/06-销售退货质检冻结与处置.md)。

### V190 新业务表后审计完整覆盖门禁

`V190__refresh_audit_trigger_coverage.sql` 在 V188/V189 新表出现后重跑完整 fail-closed sweep：公开业务表必须恰有一个 `trg_audit*`，且为启用的 AFTER ROW、同时覆盖 INSERT/UPDATE/DELETE、调用批准的脱敏审计函数。已有合法触发器不重复创建；缺失时只为**以后操作**补挂 `fn_audit()`。

V190 不修改业务数据、不扫描回填历史 `audit_log`，也不能证明迁移前操作已被记录。目标库必须用 Flyway 应用并执行触发器矩阵契约/实库探针；任一表重复、禁用、事件位不全或函数不受信都应阻断迁移，而不是手工删记录绕过。

### V196–V202 计划申请分解、订货财务审批与超量到货

> 历史版本边界(2026-08-09)：当时V191–V202已包含于公司目标库V238；但迁移应用不替代
> 非空数据对账、恢复演练和真实岗位/实物 UAT，不能据此放行相应业务链。

- `V196` 新建 `procurement_order_approval_cases/events`、`inbound_expectations/items`（原建 `workflow_responsibility_assignments` 已于 V229 删除，见 ADR-027）。生产物料分析按用户所选缺口下达采购/委外申请，业务端只读并跨申请选行、部分分解；一张订货单限一个供应商/委外商（订货仓库约束已随 V292/ADR-038 撤销）。V196 历史复合 `finance_order_approval:review` 已由 V328 停用并保真展开为 `:approve` / `:reject`。订货保存草稿后提交，通过才令订单 `status=1`、回写申请累计并生成预计到货。合格审核人只在精确 PENDING case 上临时读取隐藏详情；唯一写协议是 `{caseId,expectedVersion}` batch，决定、业务副作用和决定 receipt 同事务，case 结束后恢复普通对象范围。旧业务单笔路径只返回 fail-closed 提示。
- `V197` 对 V196 新表重跑完整审计覆盖；`V198` 消除父部门授权向计划泄漏商业单据；`V199` 以 `v_procurement_decomposition_tasks` 统一扣除已生效量和其它 `PENDING` 财务订单占用；`V200` 继续阻断计划继承委外商业字段及供应商主档。
- `V201` 新建 `procurement_arrival_exceptions`、`supplier_return_tasks`、`procurement_arrival_exception_events`，并以数据库守卫把财务追加额度绑定到具体收货单。发现超量时只提交异常/Outbox 后返回 409；库存、AP、订单累计和收货状态都不改变。现行批准走 `finance_order_approval:approve`，不批超量走 `finance_order_approval:reject`；V328 对旧 `finance_order_approval:review` 授权做保真展开，不再把旧复合码写成当前门禁。服务端收窄草稿数量/金额，未批准量只交原下单账号完成供应商退回，批准量仍须仓库再审。
- `V202` 不是“仅给上述三表挂触发器”的定向脚本，而是再次遍历全部 `public` 业务表：缺触发器才补 `fn_audit()`，重复、禁用、非 AFTER ROW、I/U/D 不全或函数不受信均 fail-closed。它只记录 V202 应用后的未来操作，不补造历史审计。

数量基准示例：订单财务已批 10 吨且尚未收退，本次草稿到货 100 吨，则批准余量 10、请求超量 90。`APPROVE_ALL` 接受 100/退回 0；`APPROVE_CUSTOM(customApprovedExcessQty=5)` 接受 15/退回 85；`REJECT_EXCESS` 接受 10/退回 90。三种情况在财务决定后仍未写库存/AP；接受量只有仓库再审成功才过账。若决定时批准余量已因并发变为 0，不批将删除该草稿行并直接形成 100 吨退回任务。

Flyway 已应用迁移必须保持原字节、文件名和顺序；任何共享环境一旦执行 V196–V202，修正只能新增 V203+。API、权限、状态与委外 `check_qty/girth_qty` 调整见 [Java 后端契约 §十](28-Java后端契约.md#十计划需求分解订货财务审批与超量到货专用契约v196v202)。

### V230 生产计划自底向上整树确认迁移门禁（历史兼容）

`V230__production_plan_bom_depth_and_auto.sql` 是纯加法迁移：给 `production_plans` 加 `bom_depth INT NULL`（MAKE 树距根深度，0=根）和 `auto_generated BOOLEAN NOT NULL DEFAULT FALSE`（标记 orchestrator 自动建的子计划）+ 两个 partial 索引。**不修改任何业务数据、不回填历史行、不增删约束/触发器**，旧行两列保持 NULL/FALSE。

- 目标库执行前后必须满足：`production_plans` 行数与历史 `status/bill_no/source_doc_no` 等不变；`auto_generated` 全库为 FALSE（仅新 orchestrator 调用才写 TRUE）；`bom_depth` 全库为 NULL（仅自动子计划写值）。
- 该两列只服务 [ADR-028](../99-决策记录-ADR/ADR-028-计划部自底向上整树确认.md) 的自底向上整树确认（`BottomUpPlanOrchestrator.confirmFullTree`，能力开关 `production.bottom-up-orchestrator.enabled` **默认关**）：`bom_depth` 驱动「最深层可开工优先」UI 排序，`auto_generated` 使级联回退只作用于自动子。迁移本身不开启该能力，历史计划绝不自动展开或重排。
- 无 BOM 的自制叶子件不被 confirm 展开（其 snapshot 内联 goods_bom_items 会得空产品行）；它由应用层报工 + 成品入库直接生产，与人工流程一致。本迁移不改变该语义。

V230/ADR-028 的 orchestrator 默认关闭，且不再是新业务目标。V234 新链路先创建物料分析和
MAKE_COMPONENT child demand，由用户在子件齐套后分批形成正式计划；不得重新开启“递归自动创建正式
子计划”来绕过分析、路线确认、分批计划或批准事务。历史 `bom_depth/auto_generated` 字段和旧计划保持原样。

### V247–V250 阶段化齐套、精确执行需求与来源谱系门禁

| 迁移 | 结构与数据策略 | 上线前必须证明 |
|---|---|---|
| `V247__bom_control_stage_and_packaging_measurement.sql` | BOM 新增 `control_stage/hard_gate` 与 `PER_UNIT/PER_PACKAGE/FIXED_BATCH` 包装规则；分析节点冻结边规则和 start/finish/ship 分配，item 新增三类 ready 量。历史 BOM 默认 START/PER_UNIT；旧分析保留 `LEGACY_CUMULATIVE_PER_UNIT`，重置旧组合预览 | 包装基数/尾包策略已由业务复核；`ready_now=ready_finish`、`ship<=finish<=start`；旧分析不从当前 BOM 反推；迁移前后需求/计划/link 守恒 |
| `V248__production_exact_material_demand_snapshot.sql` | `production_material_demands` 新增 `LINEAR/EXACT_SNAPSHOT`、段产品量及规则指纹；非线性需求身份和数量不可原改 | 每个非线性段的产品量、精确基本数量和 SHA-256 指纹一致；不存在用六位平均率还原整包/固定批次 |
| `V249__execution_segment_material_requirement_shape.sql` | 执行段显式 `DEMANDED/ZERO_MATERIAL`；ZERO_MATERIAL 只允许 `DIRECT_MAKE`、`PLAN_BOM_OVERRIDE`、`NO_PRODUCTION_HARD_GATE` 三类证据，前两类冻结分析/授权事实，第三类冻结“BOM 存在且无生产硬门槛”的形状；无需求、无 DRAW、不得 WAITING，无法从历史证据分类时迁移 fail closed | DEMANDED 全有完整需求；ZERO_MATERIAL 全有合法证据且无假需求/预留/DRAW；历史未分类行已人工处置并留证 |
| `V250__preplan_external_supply_source_guards.sql` | 外部化 action/allocation 的身份与 route/type/id 冻结；保护采购申请、委外申请及后续订货来源行；deferred trigger 同查 OLD/NEW，来源单禁止绕过取消后复活 | action route/type/id 合法、allocation 数量守恒且下游行归属正确；批准/反向/action 推进后的通用改删被拒；取消/释放专用事务可闭环且无孤儿 |
| `V253__website_inquiries.sql` | 官网询盘汇入表、审计触发器和最小权限；与生产车间建议无关 | 官网 source_id 幂等、权限/对象处理、审计、历史零回填和目标环境 UAT 单独验收；不得据此增加第二套产品默认车间字段 |

上述迁移不会自动创建采购或委外商业订货。物料分析通知只生成用户勾选缺口对应的采购申请、委外申请
或 MAKE child；采购/委外人员仍须从任务中心分解并提交正式订单财务审批。只有 IQC 合格且真实入库数量
进入当前齐套，待检/拒收/预计到货不得计入现货。普通 generate 只写计划草稿和 SUBMITTED link；批准
才原子形成 READY、LINEAR/EXACT_SNAPSHOT 需求、完整预留、DRAW、销售分摊和 APPROVED link。

V250 迁移前必须先执行只读审计，至少核对：外部 action 的 route/type/id 三元组、每个 action 的
allocation 汇总、allocation.external_item_id 对应的申请/应用/MAKE child 归属、下游订货行来源、
CANCELLED action 与来源单状态。任一不一致都应阻断迁移，不得用 `flyway repair`、删触发器或手工断链掩盖。

---
