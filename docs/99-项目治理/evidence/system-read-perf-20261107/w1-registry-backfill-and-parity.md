# W1（P1 导入判定登记表）本机副本库实测 2026-11-07

环境：5434 容器 `uten-imp-postgres-5434`；公司数据副本库 `uten_desktop_update_2534_20261026`（V946，全部单据为导入数据）及其克隆 `uten_perf_w1_scratch` / `uten_perf_w2`（V1115）。全部探针事务内执行（BEGIN…ROLLBACK / 只读），未写任何库。

## 1. 回填与登记表规模

| 项 | 值 |
|---|---|
| 登记表行数（全部导入行，含自带键+继承） | 1,920,397 |
| 登记表体积 | 269 MB |
| 迁移回填耗时（v1 版本，全行 walk） | 8:03.9 |
| 迁移回填耗时（直键列短路后） | 6:47.9 |
| 克隆库整链迁移 V946→V1115（Flyway 182 个迁移） | 632.3 s，其中 V1115 约 6:48 |

## 2. 等价性对拍（登记表谓词 ≡ 权威遍历）

- 32 张 NATIVE_TABLES：旧读法（JSON 键预筛 + 纯 `_internal` 遍历）与新读法（键列 IS NULL + `NOT EXISTS(登记表)`）对称差 = **0**。
- `stock_movements`（56 万行、无自身键、100% 继承导入）：逐行 `fn_imported_business_document_row_internal(...) <> EXISTS(登记表)` 不匹配数 = **0**（3:18.8 验证耗时）。
- 全守卫表不变式测试（`ImportedBusinessNativeSourcePostgresTest.everyGuardedUuidRowIsRegisteredExactlyWhenTheAuthorityClassifiesItImported`）在真实 V1115 库通过：260 张守卫表中每张 UUID 身份表逐行 `walk <> registered` = 0，且登记表无守卫表之外的行。

## 3. 读路径计时（同库同数据对照）

| 查询 | 改前（V946 旧读法） | 改后（V1115 登记表） |
|---|---|---|
| `v_procurement_decomposition_tasks` 全量 count（26,381 行） | 440 ms | 897 ms（视图自身，冷）→ 稳态低于改前 |
| 采购候选 + 原生判定 count | 3,886 ms | 2,626 ms（首次）/ 336–386 ms（热） |
| `nativeTable('stock_document_items')` 计数（62 万行） | 走逐行函数 | 1.4 ms（EXISTS 反连接，无函数节点） |
| 履约视图 EXPLAIN | 计划含 `fn_imported_business_document_row` 函数节点 | 计划仅 `Index Only Scan imported_document_registry_pkey` 反连接，无任何来源判定函数节点 |
| 关单已审 10,139 张上 `fn_procurement_order_reserves_source` 全表过滤（W2 前置测量） | 625/551 ms | —（V1116 后退出候选，见 W2） |

## 4. 读路径零遍历断言（真库测试）

- `ImportedDocumentAncestryWalkPostgresTest.readPathClassifiesThroughTheRegistryWithZeroGraphWalks`：uten 只读会话按登记表谓词查询，事务内 `pg_stat_xact_user_functions`（入口+遍历）计数 = 0，且返回行与权威函数逐行一致。
- `MaterialAnalysisNativeCandidatePostgresTest`：主读路径 walks=0、registry 查找>0；加入 4 张无关已审已入订单后查找次数不变。
- `IqcDecideReportBatchPostgresTest` / `ProductionMaterialAnalysisScalePostgresTest`：EXPLAIN 探针断言 walks=0、registry lookups ≤ bound。

## 5. 写路径与守卫

- 守卫 UPDATE 判定输入未变：OLD 一次遍历（计数=1）；输入变化：OLD+NEW 两次（=2）；改 FK/多态引用指向导入源：仍 55000 拒绝。
- 维护身份写：自带键/继承 INSERT 登记行、UPDATE 重键清除旧行并按行同步、DELETE 清行、TRUNCATE 清表；非维护会话调 `fn_refresh_imported_document_registry` → 42501。
- `WorkshopDirectTransferBatchEndToEndTest`（≤59 守卫行事件预算）14/14 通过；触发器计数口径只数返回 trigger 的函数，不受守卫内部权威调用变化影响。

## 6. 迁移/部署注意

- 迁移在维护身份下回填（Flyway 账号即维护身份）；公司库回填预计同量级（约 190 万行、6–9 分钟），期间持登记表与各守卫表的锁，须在维护窗口执行。
- 后续增量导入已接入：`legacy_migration/migrate_finalize_checks.sql` 在导入事务内调用 `fn_refresh_imported_document_registry(NULL)`；任何 FK/守卫/根表/映射变更或禁用守卫的数据修复，必须同事务对受影响表重算登记（V1115 头注契约）。
- 导入目标库守卫清单已登记 `imported_document_registry` 为 EMPTY（新库首次迁移时为空表）。
