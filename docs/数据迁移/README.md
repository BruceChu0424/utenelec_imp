# 老库数据迁移 · 总索引

> **当前迁移总状态（2026-08-11）**：源码最高 V252，共 233 个迁移文件；开发原库 `uten_imp`
> 实测保持 V244/installed_rank 225，既有一次性隔离克隆已真实迁移到 V250/installed_rank 231；本轮 PostgreSQL 16.14 Testcontainers 已验证 233 个迁移并到达 V252，
> 公司目标库仍保留 V238 既有只读证据。生产备份、V239–V252 正式迁移、全表及金额/数量/来源谱系
> 对账尚未执行。统一证据和待办见
> [2026-08-09 本地云端部署与生产就绪清单](../99-项目治理/2026-08-09-本地云端部署与生产就绪清单.md)。

> **货品批量导入审计增量（2026-08-11）**：V251 新增 `goods_import_batches` 与 `goods_import_creations`，分别保存导入/撤销状态和本批新建实体来源；两者都是解释、限定和追溯撤销的业务事实。V252 在不修改已应用 V251 的前提下重跑 fail-closed 全表审计覆盖，为缺失表补建唯一有效的 `trg_audit%` AFTER ROW I/U/D 触发器并复核全库契约。V252 只保护迁移后的新变化，不补造历史审计；公司目标库应用、`pg_trigger` 矩阵和导入/撤销岗位 UAT 未完成前不得视为生产放行。

> **生产物料分析重构增量（2026-08-10）**：现行序列为 **V234/V237/V239 与 V247–V250**。V234 新增计划前需求、全树物料快照、供应动作、命令幂等和计划分批链接；V237 刷新新增公开业务表未来写入的审计覆盖且不补历史；V239 允许节点剩余 `required_qty` 在全量 plan-link claim 后合法归零，修复整批生成终态被旧 `> 0` 约束拒绝的问题；V247 冻结阶段/包装边及 start/finish/ship 三个 ready 字段，其中当前 ship 等于 finish 的参考投影而不是独立硬门槛；V248 冻结非线性精确执行需求，V249 显式区分 DEMANDED/ZERO_MATERIAL，V250 保护外部化申请/订货来源谱系。详见 [56-生产计划前需求与物料分析重构](56-生产计划前需求与物料分析重构.md)和本文 V247–V250 节。隔离 PostgreSQL 和真实 HTTP 证据不等于目标库迁移、历史对账或真实岗位/实物 UAT，生产写链路仍为 **NO-GO**。

> **销售待收/应收/分批收款增量（2026-08-08）**：V236 增加 AR 收款拆分、行级汇率/冲销/余额快照和销售订单来源；V237 刷新审计覆盖；V238 在不改变已部署 V236 checksum 的前提下保守撤回不能证明安全的历史原币合成，并补启用的手续费/汇兑损益科目。详见 [20-销售管理](20-销售管理-新库与迁移.md) §十二、[26-钱流管理](26-钱流管理-新库与迁移.md) §十四与 [ADR-030](../99-决策记录-ADR/ADR-030-销售待收计划与正式应收分层.md)。目标库历史分类对账、回滚演练和财务 UAT 未完成前生产仍为 **NO-GO**。
>
> **附件对象存储 + 双服务器云端授权实现（2026-08-09）**：V240 建通用附件元数据与权限，V241 建默认关闭的 `users.remote_access`，V242 刷新审计触发器覆盖，V243 增加附件对象唯一/正大小约束，V244 保存服务端确认时实际读取并哈希的 OSS `versionId`/ETag。已实现并有自动化/真实 PostgreSQL 证据的安全边界包括：上传授权绑定用户、业务单据、key、类型和大小；业务域对象级查看/管理授权；确认时服务端校验实际内容并计算可信 SHA-256；校验、下载、删除固定精确 `versionId`；点击时重新授权并签发短时下载授权；`prod`/`cloud` profile 对非 OSS、未启用强制版本控制或非 HTTPS endpoint 启动失败。生产本地/云端必须共用同一私有 OSS Bucket；目标 OSS 尚未验收。
>
> **附件生产发布门禁**：V244 为本地存储/旧数据兼容而不强制所有行非空，但真实 OSS/云端切换前，目标库 `SELECT count(*) FROM attachments WHERE storage_version IS NULL;` 必须返回 `0`；否则必须隔离，或人工核验精确对象版本与服务端哈希后回填，禁止回退读取 latest。OSS PostPolicy（或等价）的 `content-length-range` 硬门禁、staging→扫描→final/隔离、真实 AV、删除 outbox/重试、未确认孤儿对象的配额/清理/对账，以及真实 OSS/CORS/RAM/精确版本 GET/DELETE/恢复演练仍未完成。
>
> 云端架构是**本地唯一写主库 + 异步物理热备**，链路断开时公司继续写、远程整体 503，不存在双边写入后的自动合并。部署与真实故障矩阵见 [cloud Runbook](../../deploy/cloud/README-cloud.md) 和 [ADR-031](../99-决策记录-ADR/ADR-031-本地云端单主库部署架构.md)。当前真实目标库、阿里云 ECS/VPN/OSS、PITR 与故障切换尚未验收，不能表述为“填 `.env` 即可上线”，生产保持 **NO-GO**。

<!-- PRODUCTION-PLANNING-V195-CURRENT -->
> **历史记录：生产计划迁移增量（2026-08-02）**：以下 V190/V191–V195 状态只说明当时的迁移设计，
> 不代表 2026-08-10 当前版本或目标库事实。V191 预排草案、V192 车间建议、V193 审计覆盖刷新、V194 MAKE 供给生命周期/三态人工放行/生产组织层级守卫，以及 V195 在 V194 后再次刷新审计覆盖，均为当时候选迁移，详见 [52-生产预排审核下达与车间建议](52-生产预排审核下达与车间建议.md)。新数据处置为 `READY`、`AUTO_WAIT`、`DEFERRED`；`release-defer` 只允许 DEFERRED 单向人工放行并立即重做齐套。车间、班组、负责人和日期由应用层与 V194 数据库守卫共同校验。V191–V195 全部禁止历史业务回填：不重算旧 BOM/计划、不补造计划包/子计划/供给分摊、不从旧单猜车间或延期状态；V193/V195 只保护迁移后的未来写入，不补历史审计。当前目标库/源码边界以本页顶部 2026-08-10 状态为准。

> 本文件夹是「老库 `YTDQ_2023` → 新库」数据迁移的**执行中心**。
> 看本 README 就懂：每个模块迁什么、代码在哪、怎么一键迁移、怎么加新模块。
> 现行融合策略是“按模块幂等迁移、对账、统一切换写入口、老模块只读”，见
> [ADR-017](../99-决策记录-ADR/ADR-017-模块化单体与异步旁路.md) 和
> [老系统融合总策略](../06-老系统融合/00-融合总策略.md)。

---

## 🚨 执行边界：尚未形成“平台上线后直接用”的全量增量迁移

当前有两条不同能力，不能混称“一键迁移”：

| 入口 | 覆盖范围 | 写入方式 | 可用于切流后追平 |
|---|---|---|---|
| Java `/api/admin/legacy-migration/all` | 仅货品/模具/客户/供应商四棵 `SystemItem` 分类树 | 按 `legacy_id` upsert | 只对这四棵分类树成立 |
| `server/legacy_migration/migrate.sh` | 主档及采购/库存/销售/委外/生产/钱流等模块 | `TRUNCATE`/重建目标模块 | **不可以**；只用于首次导入或迁移演练 |

Java `/all` 的单模块失败会继续后续模块，但对客户端只返回稳定
`LEGACY_MIGRATION_MODULE_FAILED` 和随机 UUID `referenceId`；异常类型、数据库地址与底层 message
不得回显，完整异常留在受控服务端日志并用 referenceId 关联。

Shell 脚本会拒绝无目标、未知目标和多目标调用，并要求破坏性确认；当前版本还要求目标库已应用
V134 迁移追溯结构，并在导入前验证 JSON manifest、checksum manifest 和实际 CSV 的绑定关系。
单模块示例：

```bash
bash server/legacy_migration/migrate.sh --stock-docs --confirm-destructive
bash server/legacy_migration/migrate.sh --subcontract --confirm-destructive
```

完整引导只允许在可清空的新库/演练库执行：

```bash
bash server/legacy_migration/migrate.sh --bootstrap-all --confirm-destructive
```

> **禁止**把 Java `/all` 当全平台迁移，禁止把破坏性 Shell 脚本用于已切流模块，禁止用多目标命令。
> 上线前仍需实现全量 + 增量 + dry-run + checkpoint + reject/quarantine + 对账 + 回滚的可重复迁移体系。
> 销售是顺序依赖的典型：`--sales` 只导入单据并保留 `seller_legacy_id`，HR 员工
> `legacy_id` 可用后还必须执行单独的 `--sales-owner` 回填。推荐只用 `--bootstrap-all` 的内置顺序；
> 不得把“销售表有数据”误判为 owner 归属已经完成。

> **⚠️ 数据坑（已修，迁其他含地址/备注的表时复用）**：老库 varchar 字段（地址、收货地址、备注）
> 可能含管道符 `|`。`export_legacy.ps1` 的 `Export-Query` 已做 RFC4180 引号转义（字段含
> 分隔符/引号/换行则 `"..."` 包裹、内部 `"`→`""`），配合 COPY `FORMAT csv` 正确还原。
> 不转义会 `missing data for column X`（客户主档首跑即踩）。

---

## 📦 模块清单

> 表中每个 `migrate.sh` 目标均是脚本真实支持的单目标 flag；实际执行必须再传 `--confirm-destructive`
> （或数据库名绑定的 `UTEN_CONFIRM_DESTRUCTIVE_MIGRATION`）。各目标必须分开调用，只有显式
> `--bootstrap-all` 会按内置依赖顺序执行全量引导。

| 模块 | 状态 | 老库来源 | 新库表 | 迁移代码 | 文档 |
|---|---|---|---|---|---|
| **货品分类** | ✅ 已实现 | `SystemItem` (ItemclassID=1) | `material_categories` | `migrate.sh --goods` | [02-老库溯源](02-货品分类-老库溯源.md) · [03-新库与迁移](03-货品分类-新库与迁移.md) |
| **货品主档** | ✅ 已实现 | `B_Goods`（35750 条，全 78 字段，image 留空） | `goods` | `migrate.sh --goods-data` | （字段映射见 V32__goods.sql） |
| **货品组装（BOM）+ 成本预算** | ⛔ 待业务处置拒绝行 | `B_BomItem`（218,820 行；正确孤儿 20,798）/ 成本列随主档 | `goods_bom_items`（有效源迁移 198,022；另有新系统手工行） | `migrate.sh --goods-bom --confirm-destructive` | [31-组装BOM与成本预算](31-货品组装BOM与成本预算.md)；V181 隔离 81 条误接占位边，计数守恒不等于零数据丢失 |
| **即时库存** | ✅ 已实现 | `View_IOStockGoods` 口径：`StockGoods.FactQTY/FactWeight` + `B_Goods.Paper/CTotal` + `View_ProductMore`（F_PlanItem） | `stock_balances`（**V80 增 weight**；余额含重量 1,288 行） | `migrate.sh --stock-docs`（重跑即补重量） | [32-即时库存](32-即时库存.md) |
| **模具分类** | ✅ 已实现 | `SystemItem` (ItemclassID=18，65 扁平根) | `mould_categories` | `migrate.sh --mould` | [04-老库溯源](04-模具资料-老库溯源.md) · [05-新库与迁移](05-模具资料-新库与迁移.md) |
| **模具主档** | ✅ 已实现 | `B_Mould`（1605 条，12 字段） | `moulds` | `migrate.sh --mould-data` | （字段映射见 V34__mould.sql） |
| **颜色** | ✅ 已实现 | `B_Color`（151 条，**实测扁平**非树；`B_Goods.MColorID` 引用） | `colors` | `migrate.sh --color-data` | [10-老库溯源](10-颜色资料-老库溯源.md) · [11-新库与迁移](11-颜色资料-新库与迁移.md) |
| **基本单位** | ✅ 已实现 | `B_Unit`（66 条，扁平，与 B_Color 同构；`B_Goods.UnitID` 引用） | `units` | `migrate.sh --unit-data` | [12-老库溯源](12-基本单位-老库溯源.md) · [13-新库与迁移](13-基本单位-新库与迁移.md) |
| 模具 | ✅ 见上 | — | — | — | （已拆为「模具分类 + 模具主档」两行） |
| 员工 | ✅ 正式名录 141 人已录入（2026-08-05）；转正日期已按入职日期回填（V210/ADR-021）；老库 stub 融合键约定保留 | `B_Worker` + 《职工信息表.xls》 | `employees` / `employee_sensitive` / `positions` / `employment_history` | `build_hr_roster.py` → `migrate.sh --hr-cleanup --hr-roster --confirm-destructive`；老库 stub：`--hr-workers` | [34-人事老库迁移](34-人事老库迁移.md) · [53-人事正式名录迁移](53-人事正式名录迁移.md) · [55-转正日期回填与员工车辆联系方式](55-转正日期回填与员工车辆联系方式.md) |
| **客户分类** | ✅ 已实现 | `SystemItem` (ItemclassID=2，10根/40节点/深3) | `client_categories` | `migrate.sh --client` | [06-老库溯源](06-客户资料-老库溯源.md) · [07-新库与迁移](07-客户资料-新库与迁移.md) |
| **客户主档** | ✅ 已实现 | `B_Client`（260 条，34 字段） | `clients` | `migrate.sh --client-data` | （字段映射见 V36__client.sql） |
| **供应商分类** | ✅ 已实现 | `SystemItem` (ItemclassID=3，15 扁平根) | `supplier_categories` | `migrate.sh --supplier` | [08-老库溯源](08-供应商资料-老库溯源.md) · [09-新库与迁移](09-供应商资料-新库与迁移.md) |
| **供应商主档** | ✅ 已实现 | `B_Provider`（386 条，29 字段） | `suppliers` | `migrate.sh --supplier-data` | （字段映射见 V38__supplier.sql） |
| **币种 / 仓库** | ✅ 已实现 | `B_Currency`(3) / `B_Storage`(6) | `currencies` / `warehouses` | `migrate.sh --currency-data` / `--warehouse-data` | [15-采购 §三](15-采购模块-新库与迁移.md)（归基础资料） |
| **采购管理** | ✅ 已实现（单位歧义行待治理） | `P_Application`/`P_Order`/`P_In`/`P_Withdraw`（主+明，十几万行） | `purchase_requests/orders/receipts/returns(+_items)` + V65 报表列 + V168 历史单位安全规范化 | `migrate.sh --purchase`（`migrate_purchase.sql`） | [14-老库溯源](14-采购模块-老库溯源.md) · [15-新库与迁移](15-采购模块-新库与迁移.md)（**9 报表 + V65 迁移补全 + V168 单位治理**） |
| **库存（流水+余额）+ 仓库报表** | ✅ 已实现 | `StockGoods`(45万) + 9 类 `O_*` 单据 | `stock_movements` / `stock_balances` / `stock_documents(+_items)` | `migrate.sh --stock-docs`（含人员 *_legacy_id + B_Worker stub + 末尾刷 MV） | [16-老库溯源](16-仓库管理-老库溯源.md) · [17-新库与迁移](17-仓库管理-新库与迁移.md) · [50-盘点修正与历史处理](50-仓库盘点修正与历史单据处理.md) · **14 张仓库报表**（V67：7 单据 × 明细/汇总，`/api/stock/reports/{docType}/{detail|summary}`） |
| **销售管理** | 🟡 单据导入已实现；V187–V189 与 V220 已包含在公司目标库 V238，历史对账、对象授权和岗位 UAT 待最终验收 | `S_Order`(10653)/`S_Out`(12124)/`S_OtherOut`(1558)/`S_Withdraw`(221)（在用）+`S_Quote`(0) | `sales_orders/shipments/other_shipments/returns(+_items)` + V187 发运/仓库字段 + V188 仓库事件 + V189 退货质量冻结 + V220 客户处置 | `--sales` 导单；员工迁入后 `--sales-owner` 回填（完整流程用 `--bootstrap-all`） | [18-总路线图](18-业务四模块-总路线图.md) · [20-新库与迁移](20-销售管理-新库与迁移.md) · [39-owner 迁移/授权](39-销售单据归属授权.md)；历史不补造确认、拣货事件、质检或客户处置结论 |
| **委外管理** | ⛔ 历史发料待重迁验收 | `E_` 前缀：`E_In`/`E_SOut`/`E_WithDraw`/`E_SWithDraw`/`E_SWaste` | `subcontract_*`（8 单据） | `migrate.sh --subcontract --confirm-destructive` | 现有历史库 49,889 发料明细数量口径失真；须用修正导出重迁并复核 [22](22-委外管理-新库与迁移.md) / [42](42-财务对账单自动生成.md) |
| **生产管理** | ✅ 已实现 | `F_Plan`(7235)+Item(73388) / **`F_PlanCostItem`(1359892)** / `F_DateReport`(0) | `production_plans(+items/+costs 按年分区)` / `production_daily_reports` | `migrate.sh --production` | [18] · [23-老库溯源](23-生产管理-老库溯源.md) · [24-新库与迁移](24-生产管理-新库与迁移.md) |
| **钱流管理** | 🟡 功能主体已导入，财务验收未关闭 | `M_Get`/`M_In`/`M_Paid`/`M_Out`/`M_DPaid`/`M_OGet`/`M_Acc`/`M_Style`/`M_AllCheck` | `finance_receipts/payments/expenses/...(+_lines)` + `ar_ap_ledger` + 主档 | `migrate.sh --finance --confirm-destructive` | 总账开账、账户期初、材料领用结转和 AR/AP 对账必须由财务签字；见 [26](26-钱流管理-新库与迁移.md) / [44](44-总账子系统.md) |
| **资产与长期待摊专业子账** | 🟡 新功能安全骨架；完整生产 **NO-GO** | **无老库业务数据，本次不迁移** | V123/V140 主档兼容升级 + V183 类别、账簿、计划、审批、事件、期间、不可变批次/明细 | **无 legacy flag；禁止用破坏性脚本或手工 SQL 回填** | 只能从经财务批准的当前期间初始化；历史期初/累计额/剩余期限能力未交付。核心落账门禁默认关闭，见 [51](51-资产与待摊专业化全链路.md) / [ADR-018](../99-决策记录-ADR/ADR-018-资产与待摊专业子账及不可变过账.md) / [验收报告](../99-项目治理/2026-08-01-资产与待摊全链路实现与验收报告.md) |
| 工资 / 员工报销 / 检测 | ⏳ 待做 | 待最终探源 | 待 | 待 | V133 已建工资/员工报销新域，但老库源表、映射、导出、导入、reject 和对账尚未实现；一般费用单不是员工报销 |

> 模块对应的完整老库结构见 [01-YTDQ老库总览](01-YTDQ老库总览.md)。

---

## ⚙️ 老库连接配置与一致性要求

```yaml
app:
  legacy:
    enabled: ${UTEN_LEGACY_ENABLED:false}     # 默认关，迁移时显式开
    datasource-url: ${UTEN_LEGACY_DB_URL:jdbc:sqlserver://(localdb)\MSSQLLocalDB;databaseName=YTDQ_2023;encrypt=false}
    datasource-username: ${UTEN_LEGACY_DB_USER:}     # LocalDB 集成认证留空
    datasource-password: ${UTEN_LEGACY_DB_PASSWORD:}
```

- **dev**：指向本机 LocalDB（集成认证，账号密码留空）。
- **上线演练/最终切换**：只连接停写后恢复出的离线备份、只读副本或数据库级一致性快照。
- **禁止**让长时间 CSV 导出直接扫仍在持续写入的生产 SQL Server，否则跨表时间点不一致。
- `export_legacy.ps1` 可用 `LEGACY_DB_CONNECTION_STRING` 指向离线恢复库；连接串不得写入文档、manifest 或 Git。

---

## 🧾 导出 Manifest 与离线快照

推荐顺序：

```powershell
# 1. 停止老系统写入，取得并恢复离线备份/一致性快照
# 2. 从恢复库导出全部 CSV
powershell -ExecutionPolicy Bypass `
  -File server/legacy_migration/export_legacy.ps1 All

# 3. 核验 export_manifest.json + export_manifest.sha256；迁移入口也会自动校验
# 4. 在可清空目标库执行破坏性引导
bash server/legacy_migration/migrate.sh --bootstrap-all --confirm-destructive
```

`export_manifest.json`（formatVersion 2）当前记录：

- 导出目标、UTC 时间、源 server/database；
- 每个文件的行数、字节数和 SHA-256；
- `consistency = offline-backup-required`；
- 导出脚本 SHA、仓库 commit，以及 `export_manifest.sha256` 自身的 SHA；
- 不记录连接凭据。

`migrate.sh` 会自动：

- 拒绝 JSON/sha256 清单缺失、两份清单不属于同一导出、目标 CSV 未登记或内容被篡改；
- 将 run 的两个 manifest 指纹、迁移脚本指纹、代码 commit 和映射版本写入
  `legacy_migration_runs`；
- 将本次实际消费的文件名、SHA-256、字节数写入 `legacy_migration_run_files`。

Manifest 是“这批文件是什么”的指纹，不是数据库事务快照证明。最终迁移包还必须保存：
备份/快照 ID、停写时间、目标 Flyway 版本、执行人、run_id 和对账报告。

---

## 🔁 当前能力边界与未来增量验收

| 能力 | 当前状态 | 上线要求 |
|---|---|---|
| 四棵分类树 Java upsert | 已有 | 补源水位、删除语义、冲突与回滚测试 |
| Shell 首次引导 | 已有破坏性脚本；输入指纹与实际消费文件可追溯 | 仅在可清空库执行；必须用同一离线快照、manifest 和 run_id |
| 全模块增量追平 | **未实现** | 按稳定业务键/watermark/CDC 实现，不得 TRUNCATE |
| dry-run / reject / quarantine | V134 已有结构化 reject 表，但各模块尚未统一写入 | 所有丢弃/修复/存根均可追踪、可复核、可重放 |
| checkpoint / resume / rollback | V134 已有未来 checkpoint 表；当前 bootstrap 不推进，增量 loader 未实现 | 中断可继续，切换失败可回退且不丢新写 |
| 自动对账 | V134 已有结构化对账表；现有模块仍以分散 SQL/人工输出为主 | 统一产出计数、金额、数量、hash、孤儿和状态分布报告，并把结果写入 run |

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

server/legacy_migration/                        ← shell 离线破坏性引导（不依赖 server）
├─ migrate.sh                                   （一次一个目标；--bootstrap-all 才执行全量依赖链；强制破坏性确认）
├─ migrate_goods.sql / migrate_goods_data.sql   （货品分类 / 主档）
├─ migrate_mould.sql / migrate_mould_data.sql   （模具分类 / 主档）
├─ migrate_client.sql / migrate_client_data.sql （客户分类[递归CTE] / 主档）
├─ migrate_supplier.sql / migrate_supplier_data.sql （供应商分类[扁平根] / 主档）
├─ migrate_color.sql / migrate_unit.sql        （颜色 / 基本单位 主档[扁平，无分类]）
├─ migrate_purchase.sql                         （采购四类单据；单位确定性回填 + 歧义行诊断）
├─ export_legacy.ps1                            （老库→UTF-8 CSV；输出 JSON manifest + sha256 清单）
└─ data/                                        ← 离线 CSV + export_manifest.json + export_manifest.sha256（敏感迁移包，不进 git，受控保管）

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

每个模块迁移后必须对账（详见各模块文档「校验」段）：总数恒等、主键（`legacy_id`）覆盖、
关键金额/数量/状态汇总、外键/孤儿、抽样字段与业务单据。被跳过的数据必须进入 reject/quarantine
并由业务批准处置；“脚本成功”或“源数−跳过数=目标数”不等于迁移验收通过。

V134 提供 `legacy_migration_reconciliation_items`、`legacy_migration_rejects` 和
`legacy_migration_checkpoints` 的结构，但当前各模块迁移 SQL 尚未统一把分散校验和跳过行写入这些表。
只有 `legacy_migration_runs.reconciliation_status = PASSED` 且对应结构化明细完整，才可作为机器验收证据；
`status = SUCCESS` 只表示脚本无错误退出。

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
- 历史出货按原删除/驳回/审核状态映射为 `CANCELLED/SHIPPED/REVERSED/LEGACY_PENDING`；历史 `picking_started_at/picked_at/handed_over_at` 保持空。
- 新单数据库默认 `CUSTOMER_CONFIRM` / `PENDING_PICK`，应用仍必须显式走服务端状态机。
- 新权限 `sales_order:confirm_partial_shipment` 默认授销售部，`sales_shipment:warehouse-work` 默认授 PMC；上线前须按真实岗位复核，默认部门授权不等于最终职责分离签字。
- V90 `chain_status=0` 且无有效预留的旧未结订单不得自动变为可发。新建 V187 出货必须提前 fail-closed；业务须逐订单行对账库存、历史已发和旧排产后显式激活。当前没有自动批量激活脚本，禁止为“让页面可用”伪造预留。
- V187 不回写历史商业字段。新业务由应用从来源订单重建出货客户、币税/付款条件和行价格/金额；迁移不能替应用猜测或修复历史定价事实。

目标库执行前后至少对账：四类销售主表/明细行数和数量金额汇总不变；V187 新列 null/枚举分布符合历史映射；迁移后旧草稿仍能走兼容审核，新单不能走旧审核；无权限用户看不到动作且直接调用 403。下文“171 个迁移至 V190、真实 PG 54/54”是 2026-08-01 的历史候选证据；V187–V189 与后续 V220 当前已包含在公司目标库 V238，但这仍不能替代历史全量对账、对象权限、岗位 UAT 和发布签字，销售生产门禁尚未关闭。

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

> 版本边界（2026-08-09 更新）：V191–V202 已包含在公司目标库当前 V238 以内；但迁移应用不替代
> 非空数据对账、恢复演练和真实岗位/实物 UAT，不能据此放行相应业务链。

- `V196` 新建 `procurement_order_approval_cases/events`、`inbound_expectations/items`（原建 `workflow_responsibility_assignments` 已于 V229 删除，见 ADR-027）。生产物料分析按用户所选缺口下达采购/委外申请，业务端只读并跨申请选行、部分分解；一张订货单限一个供应商/委外商和一个仓库。订货保存草稿后提交，由财务部门持 `finance_order_approval:review` 的审核组（含跨部门点名加授者）审批，通过才令订单 `status=1`、回写申请累计并生成预计到货。应用层只允许合格审核人在精确 PENDING case 上临时打开 owner 隐藏的订单详情；决定、业务副作用和响应详情同事务，case 结束后恢复普通对象范围。
- `V197` 对 V196 新表重跑完整审计覆盖；`V198` 消除父部门授权向计划泄漏商业单据；`V199` 以 `v_procurement_decomposition_tasks` 统一扣除已生效量和其它 `PENDING` 财务订单占用；`V200` 继续阻断计划继承委外商业字段及供应商主档。
- `V201` 新建 `procurement_arrival_exceptions`、`supplier_return_tasks`、`procurement_arrival_exception_events`，并以数据库守卫把财务追加额度绑定到具体收货单。发现超量时只提交异常/Outbox 后返回 409；库存、AP、订单累计和收货状态都不改变。由财务部门持 `finance_order_approval:review` 的审核组（含个人加授者）决定全批、自定义批准或不批超量；服务端收窄草稿数量/金额，未批准量只交原下单账号完成供应商退回，批准量仍须仓库再审。
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

上述迁移不会自动创建采购或委外商业订货。物料分析通知只生成用户勾选缺口对应的采购申请、委外申请
或 MAKE child；采购/委外人员仍须从任务中心分解并提交正式订单财务审批。只有 IQC 合格且真实入库数量
进入当前齐套，待检/拒收/预计到货不得计入现货。普通 generate 只写计划草稿和 SUBMITTED link；批准
才原子形成 READY、LINEAR/EXACT_SNAPSHOT 需求、完整预留、DRAW、销售分摊和 APPROVED link。

V250 迁移前必须先执行只读审计，至少核对：外部 action 的 route/type/id 三元组、每个 action 的
allocation 汇总、allocation.external_item_id 对应的申请/应用/MAKE child 归属、下游订货行来源、
CANCELLED action 与来源单状态。任一不一致都应阻断迁移，不得用 `flyway repair`、删触发器或手工断链掩盖。

---

**最后更新**：2026-08-11。顶部同步源码 V252/233（V251 货品导入，V252 审计覆盖）、开发原库 `uten_imp` V244/225、一次性生产物料克隆 V250/231、公司目标库 V238 既有只读证据，以及 V247–V250 生产分析/执行/来源门禁；
下文保留 V190、V191–V202 等当时章节作为历史迁移设计，不得覆盖顶部当前事实。
迁移脚本和多数业务映射已经形成，但当前发布结论仍为
**NO-GO**：BOM 20,798 条拒绝行、委外发料 49,889 条历史数量、客户归属计数、
总账开账/材料结转，以及全模块增量追平/回滚尚未关闭。财务 API/UI 已实现不等于财务数据已签字验收；
一般费用单也不等于员工报销。销售—仓库—计划—生产/采购/委外当前边界以
[2026-08-01 全链路安全复核报告](../99-项目治理/2026-08-01-销售仓库生产采购委外全链路安全复核报告.md)为准；
[生产就绪审计报告](../99-项目治理/2026-07-30-生产就绪审计报告.md)保留历史审计，最终发布仍须目标库对账与签字报告。
